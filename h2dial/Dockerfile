# Multi-stage build for h2dial.
#
# Stage 1: build the static Go binary in a clean module.
# Stage 2: distroless static runtime, ~3 MB image.
#
# The image is built locally and imported into the k3d cluster via
# `k3d image import h2dial:local --cluster <cluster-name>` (no registry
# round-trip needed). deploy.sh handles this end-to-end.

# Base images are pinned by digest, not tag, so two builds weeks apart
# produce byte-identical layers regardless of upstream tag movement.
# To bump:
#   docker pull golang:1.25-alpine                 # or the new tag
#   docker inspect --format='{{index .RepoDigests 0}}' golang:1.25-alpine
# then paste the new sha256 below. Same for the distroless runtime.
# The Go module lockfile (go.mod + go.sum) handles dep drift; this pin
# handles toolchain + libc + ca-cert drift in the builder/runtime images.
FROM golang:1.25-alpine@sha256:c05ba4b73604069d376c4f41346b05374335b5ca0c46fb6dfede5a59f5196931 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /h2dial main.go

FROM gcr.io/distroless/static-debian12@sha256:9c346e4be81b5ca7ff31a0d89eaeade58b0f95cfd3baed1f36083ddb47ca3160
COPY --from=build /h2dial /h2dial
# /bin/sh is NOT available in distroless. The keep-alive mode is invoked
# via `args: ["-idle"]` in the Deployment spec; load runs are kubectl exec
# invocations of /h2dial directly.
ENTRYPOINT ["/h2dial"]
