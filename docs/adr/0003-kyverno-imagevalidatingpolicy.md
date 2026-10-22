# ADR-0003: Kyverno for admission control (ImageValidatingPolicy)

**Status:** accepted · **Date:** 2026-10-22

## Context
The cluster must refuse images the pipeline did not sign. Options: Kyverno, OPA Gatekeeper (+ an external
verifier), Sigstore policy-controller.

## Decision
Kyverno v1.19 with the CEL-based `ImageValidatingPolicy` (`policies.kyverno.io/v1`). The legacy
`ClusterPolicy` type is marked deprecated by Kyverno, so new policy is written in the new API.

## Consequences
- Native cosign verification, readable YAML/CEL, no Rego to maintain.
- Kyverno needs registry credentials and the lab CA (node CA bundle mounted via Helm values).
- Single admission replica in the lab; production needs ≥3 and a decision on `failurePolicy`.
