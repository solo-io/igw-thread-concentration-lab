# Security policy

## Reporting a vulnerability

This is a learning and diagnostic lab. It is **not** a Solo.io product, and the Solo.io product security team does not own its bug-fix lifecycle.

That said, if you find a security issue (in the lab itself, in dependencies it ships with, or in the published Docker images that scenarios use), please report it privately rather than opening a public issue:

- File a private security advisory via this repository's GitHub Security tab, or
- Email the maintainer (see `CODEOWNERS`).

For vulnerabilities in **upstream products** that the lab merely exercises (Istio, Envoy, Kubernetes, k3d, Helm, kube-prometheus-stack, fortio, ghz, grpcbin, etc.), please report them upstream directly.

## Scope

In scope:

- Issues in the lab's scripts, manifests, Dockerfiles, or `h2dial` Go code that could be exploited if a user runs the lab in an untrusted environment.
- Hard-coded credentials, secrets, or tokens in the lab's source.
- Dependencies pinned in this repository that have known unpatched CVEs.

Out of scope:

- The Grafana `admin/admin` default credentials baked into `deploy.sh`. The lab is intentionally a local dev environment with no production data; the default password is documented and called out in the deploy script. If you are deploying this lab in a shared environment, change it.
- Issues in upstream Istio, Envoy, or Kubernetes (report those upstream).
- Issues that require root access to a host already running the lab.
