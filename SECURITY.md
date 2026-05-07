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

- The Grafana convenience credential baked into `deploy.sh` (default `admin` / `lab-igw`, configurable via `GRAFANA_ADMIN_PASSWORD` in `config.env`). The lab is intentionally a local k3d environment with no production data; the credential is documented in `config.env.example` and printed by `deploy.sh` at the end of every deploy. The password is deliberately NOT the literal `"admin"` because Grafana 9.5+ force-prompts a password change on first UI login when the password matches the default, which silently breaks Basic-auth calls from `run-tests.sh`'s screenshot-render path the moment a human opens the dashboard. The chosen non-default value plus `[security] disable_initial_admin_password_change = true` in the rendered grafana.ini lets human + automation share the same credential without interruption. If you are deploying this lab in a shared environment, override `GRAFANA_ADMIN_PASSWORD` in `config.env`; do NOT leave it at the documented default.
- Issues in upstream Istio, Envoy, or Kubernetes (report those upstream).
- Issues that require root access to a host already running the lab.
