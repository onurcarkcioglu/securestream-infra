# ADR-0006: Pin CI tools by digest and wait ~2 weeks before upgrading

**Status:** accepted · **Date:** 2026-10-22

## Context
In March 2026 attackers published malicious Trivy releases and re-pointed GitHub Action tags
(CVE-2026-33634). Pipelines that pulled by tag executed an infostealer; digest-pinned pipelines did not.

## Decision
Every CI tool image is referenced as `image:tag@sha256:…`, resolved by `scripts/pin-images.sh` in `securestream/ci-templates`, one `templates/images.yml` for all projects. New releases
are adopted roughly two weeks after publication unless they fix a vulnerability we are exposed to.

## Consequences
- Reproducible pipelines; a moved tag cannot change what runs.
- Upgrades are deliberate commits (reviewable diffs of digests).
- We may run a slightly older version; security fixes override the cool-down.
