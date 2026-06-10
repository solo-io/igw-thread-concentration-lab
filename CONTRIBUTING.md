# Contributing

This lab grows by accumulating well-isolated scenarios that teach one thing each. Contributions are welcome.

## Quick guidelines

- **One variable per scenario.** Each new scenario should isolate exactly one knob, behavior, or hypothesis. Stacked-knob scenarios lose attribution and aren't useful as teaching tools. If you want to test a stack, document the stack in `PLAN.md` and run the scenarios in sequence.
- **State the hypothesis before adding the scenario.** Update `PLAN.md` first with what you expect to see, what would confirm it, and what would refute it. Refutations are a feature, not a failure: a hypothesis that doesn't hold is itself a finding.
- **Add the scenario to `run-tests.sh`.** Follow the pattern of existing scenarios: apply the EnvoyFilter, run the load gen, capture stats, write to `results/<ts>/<scenario>/`.
- **Update the README's scenario table** with a "What it teaches" and "What to watch" entry. The reader should know why your scenario exists without reading the manifests.
- **Don't include customer- or organization-specific content.** This repo is public. No customer names, ticket IDs (Zendesk, JIRA, Linear), internal Slack URLs, real cluster IDs, ARNs, project IDs, or proprietary configuration. Sanitize as you write rather than as you push. The `.github/PULL_REQUEST_TEMPLATE.md` checklist enforces this on review.

## Adding a scenario

```
manifests/envoyfilters/scenarioNN-<name>.yaml   # the EnvoyFilter (one knob varied)
run-tests.sh                                    # add the scenario block
PLAN.md                                         # add the hypothesis (or refutation)
README.md                                       # add the row to the scenarios table
```

Re-run `./run-tests.sh --only NN-<name>` until the signal is clean. Then run the full suite once before committing to confirm you haven't perturbed anything else.

## Configuration

Tunable settings (cluster name, pinned versions, replica counts, scenario durations, image pins) live in `config.env.example`. To customize without touching the scripts, copy it to `config.env` (gitignored) and edit there. The scripts source `config.env` if it exists; defaults baked into the scripts are used otherwise. If you add a new knob that ought to be adjustable, surface it in `config.env.example` with a comment explaining the trade-off, and add a `: "${VAR_NAME:=<default>}"` line to whichever script consumes it.

## Style

- Bash scripts use `set -euo pipefail` and explicit `--context $CONTEXT` on every `kubectl`, `helm`, and `istioctl` call. Don't rely on the default context.
- Comments explain *why*, not *what*. The code already says what.
- Avoid em-dashes in prose (`--` or `&mdash;`). Use periods, semicolons, parentheses, or colons.
- Markdown reference links over bare URLs.

## Reporting issues

Open an issue on the repository describing what you ran, what you expected, and what happened. Attach (or paste) the relevant slice of `results/<ts>/<scenario>/`; the per-scenario stat dumps and time-series CSV are usually enough to triage.

## Security

See `SECURITY.md`.
