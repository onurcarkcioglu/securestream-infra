# ADR-0005: Key-based cosign signing without the public transparency log

**Status:** accepted · **Date:** 2026-10-22

## Context
Keyless signing (Fulcio + Rekor) relies on public Sigstore infrastructure and writes image names and digests
to a public log. The registry is private and offline from the internet's point of view.

## Decision
cosign v2.6 with a key pair: private key generated in RAM, kept in Ansible Vault and as a protected, hidden
CI variable; signatures uploaded with `--tlog-upload=false`; Kyverno ignores tlog/SCT for this key.
cosign v2 is used because its signature format is verified by Kyverno without extra configuration.

## Consequences
- No metadata about private images leaks to a public log.
- We own key protection and rotation (runbook).
- Migration path: cosign v3 bundle format, or a private Rekor, or KMS-backed keys in a cloud setup.
