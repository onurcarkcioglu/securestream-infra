# ADR-0004: Kaniko (maintained fork) for image builds

**Status:** accepted · **Date:** 2026-10-22

## Context
Docker-in-Docker requires a privileged runner, which gives every CI job root on the runner host.
Google archived Kaniko in 2025; a community fork (`osscontainertools/kaniko`) is maintained.

## Decision
Build with the maintained Kaniko fork, pinned by digest, on an unprivileged runner.

## Consequences
- No privileged containers in CI.
- Dependence on a community fork → watched like any third-party component (cool-down, pinning).
- Alternatives evaluated: BuildKit rootless (needs relaxed seccomp/AppArmor on Ubuntu 24.04), Buildah.
