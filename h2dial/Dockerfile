# Multi-stage build for h2dial.
#
# Stage 1: build the static Go binary in a clean module.
# Stage 2: distroless static runtime, ~3 MB image.
#
# The image is built locally and imported into the k3d cluster via
# `k3d image import h2dial:local --cluster <cluster-name>` (no registry
# round-trip needed). deploy.sh handles this end-to-end.

FROM golang:1.25-alpine AS build
WORKDIR /src
COPY main.go .
# Pin x/net to a version that works cleanly; latest tracks Go's main
# branch and may require newer Go than this base image. v0.40.0 is
# stable and supports Go 1.23+.
RUN go mod init h2dial \
    && go get golang.org/x/net/http2@v0.40.0 \
    && CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /h2dial main.go

FROM gcr.io/distroless/static-debian12
COPY --from=build /h2dial /h2dial
# /bin/sh is NOT available in distroless. The keep-alive mode is invoked
# via `args: ["-idle"]` in the Deployment spec; load runs are kubectl exec
# invocations of /h2dial directly.
ENTRYPOINT ["/h2dial"]
