# ghz image for scenario 12. ghz is a real gRPC load tester (Go-based,
# uses grpc-go). With --connections=1 it maintains a single
# grpc.ClientConn, which is the canonical "queue on cap" client pattern
# (a faithful stand-in for production gRPC services that share one
# ClientConn per upstream peer).
#
# We use alpine + curl to fetch the official ghz Linux binary at build
# time. The image is tagged ghz:local and imported into k3d (no registry).
# ghz only ships an x86_64 Linux binary (no linux-arm64). Force the
# platform so on Apple Silicon hosts the container runs under Rosetta
# emulation; on amd64 hosts this is a no-op.
# alpine:3.19 pinned by digest so the build is reproducible. To bump:
#   docker pull alpine:3.19
#   docker inspect --format='{{index .RepoDigests 0}}' alpine:3.19
# then paste the new sha256 below.
FROM --platform=linux/amd64 alpine:3.19@sha256:6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1
# Verify the downloaded tarball against a known-good sha256 before
# extracting. ghz does not publish a checksums.txt with its release, so
# this is the only available defense against a tampered tarball or a
# silent re-tag. Computed locally with `shasum -a 256 ghz-linux-x86_64.tar.gz`
# against the v0.120.0 release; update both the URL and the hash on
# version bump.
RUN apk add --no-cache curl ca-certificates && \
    curl -fL "https://github.com/bojand/ghz/releases/download/v0.120.0/ghz-linux-x86_64.tar.gz" \
        -o /tmp/ghz.tar.gz && \
    echo "c1b5eee89fd7c779213f198753d1d961dfbcb257bc470eb3c336f333060a6d6c  /tmp/ghz.tar.gz" \
        | sha256sum -c - && \
    tar -xzf /tmp/ghz.tar.gz -C /usr/local/bin/ ghz && \
    rm /tmp/ghz.tar.gz && \
    apk del curl
ENTRYPOINT ["/usr/local/bin/ghz"]
