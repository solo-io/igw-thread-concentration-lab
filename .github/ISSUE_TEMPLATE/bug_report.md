---
name: Bug report
about: Something in the lab broke, didn't behave as documented, or produced misleading data
title: "[bug] "
labels: bug
---

## What broke

<!-- One sentence on what went wrong. Which scenario, which step, which assertion. -->

## What you expected

<!-- What the README or PLAN.md says should happen. Quote the line if helpful. -->

## What actually happened

<!-- Error messages, unexpected metric values, missing output. Paste relevant logs in code fences. -->

## How to reproduce

<!-- Exact commands. Include flags. -->

```bash
./deploy.sh
./run-tests.sh --only <scenario>
```

## Relevant output

<!--
Attach or paste the contents of the failing scenario's results dir.
Usually the most useful files are:

  results/<ts>/<scenario>/cv.txt                            (per-scenario summary CV + p99 line)
  results/<ts>/<scenario>/h2dial-measure.txt                (or fortio-measure.txt / ghz-measure.txt, depending on scenario)
  results/<ts>/<scenario>/cx_http2_total_per_pod.txt        (per-pod connection count; the headline distribution metric)
  results/<ts>/<scenario>/flow_control_paused.txt           (relevant for H-D / windows scenarios)
  results/<ts>/<scenario>/cx_max_requests_reached.txt       (relevant for H-C / count rotation scenarios)
  results/<ts>/<scenario>/worker_cv_per_pod.txt             (relevant for H-E / scenario 13)
  results/<ts>/<scenario>/timeseries.csv                    (only on s2-trigger; metric-sampler output)
  results/<ts>/<scenario>/grafana.png                       (the dashboard screenshot for the measure window)

Also useful: the runner's full stdout (typically saved by you when you ran it),
which contains the hypothesis-evaluation block at the end.

Redact anything sensitive before pasting.
-->

## Environment

- Host OS / arch:                          <!-- e.g., macOS 14.6 / Apple Silicon, Ubuntu 22.04 / amd64 -->
- Docker version:                          <!-- `docker version` -->
- k3d version:                             <!-- `k3d version` -->
- kubectl client/server:                   <!-- `kubectl version` -->
- Helm version:                            <!-- `helm version` -->
- istioctl version (in repo):              <!-- usually 1.27.8 -->

## Anything else

<!-- Hunches, related scenarios that DO work, observations. -->
