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

  results/<ts>/<scenario>/scenario.log
  results/<ts>/<scenario>/stats_post.txt
  results/<ts>/<scenario>/timeseries.csv
  results/<ts>/<scenario>/clusters.json

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
