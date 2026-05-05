---
name: Scenario proposal
about: Propose a new scenario or hypothesis to add to the lab
title: "[scenario] "
labels: enhancement
---

## Hypothesis

<!--
State the hypothesis being tested in one paragraph. Format:

  "When [condition], [observable] [increases/decreases] because [mechanism],
   measured by [metric]."

A scenario without a clear hypothesis is just a test. We want teaching
artifacts here.
-->

## Why this isn't already covered

<!--
Which existing scenario is closest? Why is this materially different
(different lever, different client behavior, different layer of the stack)?
-->

## Expected confirmation signal

<!-- What metric moves, in which direction, by approximately how much. -->

## Expected refutation signal

<!--
A scenario that can't fail isn't testing anything. What would the metric
show if the hypothesis were wrong, and what would that finding mean?
-->

## Proposed shape

- **Client**: <!-- h2dial -mode=..., fortio, ghz, custom -->
- **EnvoyFilter**: <!-- which knob, which value, applied to which workload -->
- **Backend endpoint**: <!-- /get, /bytes/N, /delay/N, gRPC method -->
- **Number to slot in as**: <!-- 13, 14, ... or 6b, etc. -->

## Anything else

<!-- Related upstream issues, blog posts, prior tickets that motivated this. -->
