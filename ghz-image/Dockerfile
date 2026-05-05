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
FROM --platform=linux/amd64 alpine:3.19
RUN apk add --no-cache curl ca-certificates && \
    curl -L "https://github.com/bojand/ghz/releases/download/v0.120.0/ghz-linux-x86_64.tar.gz" \
        -o /tmp/ghz.tar.gz && \
    tar -xzf /tmp/ghz.tar.gz -C /usr/local/bin/ ghz && \
    rm /tmp/ghz.tar.gz && \
    apk del curl
ENTRYPOINT ["/usr/local/bin/ghz"]
