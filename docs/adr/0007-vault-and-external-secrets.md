# ADR-0007: HashiCorp Vault + External Secrets Operator for application secrets

**Status:** accepted · **Date:** 2026-10-22

## Context
Application secrets must not live in Git, Helm values or CI variables. Options: Sealed Secrets, SOPS,
Vault + ESO, Vault Agent injector.

## Decision
Vault (Raft storage, TLS, file audit) on a dedicated VM. ESO authenticates with Vault's Kubernetes auth
method using a short-lived, audience-bound service-account token; a read-only policy per application.

## Consequences
- Solves "secret zero" without a static token; access is auditable per request.
- Vault must be unsealed after restarts (Shamir 5/3, manual in the lab; KMS auto-unseal in production).
- Root token revoked after setup; administrative access requires `operator generate-root` with unseal keys.
- Note: Vault is BSL-licensed since 2023; OpenBao is the open-source fork with a compatible API.
