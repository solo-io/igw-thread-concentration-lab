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
# go.mod and go.sum are committed; the build uses them directly so the
# whole transitive dependency graph is content-hash-locked. v0.40.0 of
# golang.org/x/net is the pinned direct dep; bump by editing go.mod and
# running `go mod tidy` locally.
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /h2dial main.go

FROM gcr.io/distroless/static-debian12
COPY --from=build /h2dial /h2dial
# /bin/sh is NOT available in distroless. The keep-alive mode is invoked
# via `args: ["-idle"]` in the Deployment spec; load runs are kubectl exec
# invocations of /h2dial directly.
ENTRYPOINT ["/h2dial"]
