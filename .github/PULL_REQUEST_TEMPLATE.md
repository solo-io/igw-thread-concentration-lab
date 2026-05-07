<!--
Thanks for contributing. The checklist below isn't bureaucratic; each
item exists because skipping it has bitten the lab in the past. Tick
what applies and delete the rest.
-->

## Summary

<!-- One paragraph: what changed, why. -->

## Type of change

- [ ] New scenario
- [ ] Fix to an existing scenario
- [ ] Documentation only
- [ ] Tooling / CI / repo metadata
- [ ] Other (explain below)

## If this adds or changes a scenario

- [ ] Hypothesis stated in `PLAN.md` (claim, mechanism, confirmation signal, refutation possibility)
- [ ] Row added to the scenarios table in `README.md` with "What it teaches" and "What to watch"
- [ ] EnvoyFilter isolates one variable (no stacked knobs in a single scenario)
- [ ] `run-tests.sh` block follows the existing pattern: apply filter, run load gen, capture stats, write to `results/<ts>/<scenario>/`
- [ ] Re-ran the full suite locally and confirmed directional behavior unchanged for unrelated scenarios. (Note: at this lab's connection counts, specific CV magnitudes vary roughly 50% run-to-run; the relevant check is direction and rank-ordering, not absolute numbers. See README's "Findings (three independent runs)" for what is robust vs noisy.)
- [ ] Attached the relevant slice of `results/<ts>/<scenario>/` (or summary numbers) below

## Sanitization

- [ ] No customer names, ticket numbers, or internal links anywhere in the diff
- [ ] No secrets, license keys, or tokens (including the `Bearer <token>` pattern)
- [ ] No internal Slack or Zendesk URLs in code, manifests, or docs

## Test evidence

<!--
Paste the relevant numbers from the run. Examples:

  - CV before/after, GOAWAY rate, p99 latency
  - cv_across_scenarios.png (drag-drop)
  - The hypothesis-evaluation block from run-tests.sh stdout
-->

## Related

<!-- Issues closed, prior PRs, upstream issues. -->
