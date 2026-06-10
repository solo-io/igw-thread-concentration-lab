// h2dial: a small HTTP/2 (h2c) load client that exercises Go's
// http2.Transport connection-pool dial-on-cap behavior.
//
// Why this exists: off-the-shelf load testers (fortio, h2load, hey, oha,
// k6 in default mode) have one HTTP/2 connection per worker and queue when
// the server's SETTINGS_MAX_CONCURRENT_STREAMS limit is reached. They do
// not exercise the "smart client" behavior the lab needs to test, where a
// reduced max_concurrent_streams cap forces the client to open additional
// TCP connections instead of queueing.
//
// h2dial uses the canonical Go pattern: many goroutines share ONE
// http.Client with ONE http2.Transport. The Transport's clientConnPool
// (in golang.org/x/net/http2) opens new connections when existing ones
// are at the server's stream cap. This is the "client dials on cap"
// behavior that grpc-go with custom dialers and modern HTTP/2 stacks
// implement.
//
// Usage:
//   h2dial -url=http://host:port/path -d=60s -c=200
//   h2dial -idle    (sleep forever; for keep-alive in a Deployment)

package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/net/http2"
)

func main() {
	idle := flag.Bool("idle", false, "Sleep forever (for use as a keep-alive Deployment)")
	url := flag.String("url", "", "Target h2c URL (http:// scheme)")
	duration := flag.Duration("d", 60*time.Second, "Test duration")
	concurrent := flag.Int("c", 200, "Concurrent in-flight workers")
	mode := flag.String("mode", "shared", "Client model: 'shared' (one http.Client + http2.Transport, dial-on-cap) or 'distinct' (one Client per worker = high TCP-connection cardinality, demonstrates the low-CV reference baseline)")
	slowURL := flag.String("slow-url", "", "Optional URL to fire continuously alongside the primary URL (used for HOL-blocking tests; latency stats track primary URL only)")
	slowWorkers := flag.Int("slow-workers", 5, "Workers dedicated to the slow URL (only used if -slow-url is set)")
	headerFlag := flag.String("header", "", "Optional HTTP header in 'Key: value' format to send on every request (e.g., 'Authorization: Bearer <token>')")
	flag.Parse()

	if *idle {
		// Plain `select {}` triggers Go's runtime deadlock detection
		// when no other goroutines exist. Use a long sleep loop instead.
		for {
			time.Sleep(time.Hour)
		}
	}

	if *url == "" {
		fmt.Fprintln(os.Stderr, "missing -url")
		os.Exit(2)
	}

	// Shared mode: one http2.Transport across all goroutines. Pool dials
	// additional connections when existing ones are saturated at the
	// server's SETTINGS_MAX_CONCURRENT_STREAMS.
	//
	// Distinct mode: one http.Client per worker, each with its own
	// http2.Transport. Each Transport reuses one connection per host;
	// with N workers all hitting the same host, N TCP connections result.
	// Used for the low-CV reference baseline (scenario 1) where we want
	// many connections distributed evenly.
	mkClient := func() *http.Client {
		return &http.Client{Transport: &http2.Transport{
			AllowHTTP: true,
			DialTLS: func(network, addr string, _ *tls.Config) (net.Conn, error) {
				return net.Dial(network, addr)
			},
		}}
	}
	var clients []*http.Client
	switch *mode {
	case "shared":
		clients = []*http.Client{mkClient()}
	case "distinct":
		clients = make([]*http.Client, *concurrent)
		for i := range clients {
			clients[i] = mkClient()
		}
	default:
		fmt.Fprintf(os.Stderr, "invalid -mode=%s (want 'shared' or 'distinct')\n", *mode)
		os.Exit(2)
	}

	var totalReqs, errs int64
	// Each worker writes to its own latency slice; no lock during the run.
	// At the lab's 500 goroutines + 5k+ RPS the prior single-mutex pattern
	// serialized every request append and added a measurable floor to the
	// p99 the lab reports as a gateway-side number. Merge at the end into
	// one sorted slice for percentile computation.
	perWorkerLatencies := make([][]time.Duration, *concurrent)

	// Parse -header once. Applied to every outbound request (primary and
	// slow-URL workers alike); the parsing used to live inside the
	// primary worker's per-request loop, which both re-parsed on every
	// request and silently skipped the slow workers.
	var hdrKey, hdrVal string
	if *headerFlag != "" {
		if i := strings.Index(*headerFlag, ":"); i > 0 {
			hdrKey = strings.TrimSpace((*headerFlag)[:i])
			hdrVal = strings.TrimSpace((*headerFlag)[i+1:])
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), *duration)
	defer cancel()

	var wg sync.WaitGroup
	start := time.Now()
	for i := 0; i < *concurrent; i++ {
		wg.Add(1)
		// In shared mode all workers use clients[0]. In distinct mode each
		// worker has its own client.
		myClient := clients[0]
		if *mode == "distinct" {
			myClient = clients[i]
		}
		go func(c *http.Client, idx int) {
			defer wg.Done()
			// Pre-size for a typical 60s measure run at ~10k req/s per
			// worker. Append still grows; this just avoids the first
			// dozen reallocations.
			local := make([]time.Duration, 0, 1<<16)
			for ctx.Err() == nil {
				rstart := time.Now()
				req, err := http.NewRequestWithContext(ctx, "GET", *url, nil)
				if err != nil {
					atomic.AddInt64(&errs, 1)
					continue
				}
				if hdrKey != "" {
					req.Header.Set(hdrKey, hdrVal)
				}
				resp, err := c.Do(req)
				if err != nil {
					atomic.AddInt64(&errs, 1)
					continue
				}
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
				lat := time.Since(rstart)
				atomic.AddInt64(&totalReqs, 1)
				local = append(local, lat)
			}
			perWorkerLatencies[idx] = local
		}(myClient, i)
	}
	// HOL blocking workload: extra workers firing the slow URL on the
	// SAME http.Client (shared mode only). These do not contribute to
	// latency stats; their purpose is to occupy stream slots / connection
	// bandwidth while the primary workers measure tail latency on the
	// fast URL.
	if *slowURL != "" && *mode == "shared" {
		for i := 0; i < *slowWorkers; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				c := clients[0]
				for ctx.Err() == nil {
					req, err := http.NewRequestWithContext(ctx, "GET", *slowURL, nil)
					if err != nil {
						continue
					}
					if hdrKey != "" {
						req.Header.Set(hdrKey, hdrVal)
					}
					resp, err := c.Do(req)
					if err != nil {
						continue
					}
					_, _ = io.Copy(io.Discard, resp.Body)
					_ = resp.Body.Close()
				}
			}()
		}
	}

	wg.Wait()

	elapsed := time.Since(start)

	// Merge per-worker slices into one for percentile computation.
	totalLat := 0
	for _, s := range perWorkerLatencies {
		totalLat += len(s)
	}
	latencies := make([]time.Duration, 0, totalLat)
	for _, s := range perWorkerLatencies {
		latencies = append(latencies, s...)
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	pct := func(p float64) float64 {
		if len(latencies) == 0 {
			return 0
		}
		idx := int(float64(len(latencies)) * p / 100.0)
		if idx >= len(latencies) {
			idx = len(latencies) - 1
		}
		return latencies[idx].Seconds()
	}

	// Output is intentionally fortio-compatible for the lines that
	// run-tests.sh greps: "# target N% latency".
	fmt.Printf("h2dial summary\n")
	fmt.Printf("  url=%s\n", *url)
	fmt.Printf("  mode=%s workers=%d duration=%s\n", *mode, *concurrent, elapsed)
	fmt.Printf("  total=%d errors=%d\n", totalReqs, errs)
	fmt.Printf("  qps=%.1f\n", float64(totalReqs)/elapsed.Seconds())
	fmt.Printf("# target 50%% %.6f\n", pct(50))
	fmt.Printf("# target 75%% %.6f\n", pct(75))
	fmt.Printf("# target 90%% %.6f\n", pct(90))
	fmt.Printf("# target 99%% %.6f\n", pct(99))
	fmt.Printf("# target 99.9%% %.6f\n", pct(99.9))
}
