# Runbook: a pod was rejected — "Imza dogrulanamadi" (signature could not be verified)

**Symptom:** a Deployment does not create pods; events show
`admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-verify-securestream-images" denied the request`.

## Triage
1. Which image? `kubectl -n <ns> get events --sort-by=.lastTimestamp | tail`
2. Was it built by the `main` pipeline? Only `main` signs. A branch build is expected to be rejected.
3. Verify manually on ss-mgmt:
   `cosign verify --key ~/securestream/infra/ansible/files/cosign.pub --insecure-ignore-tlog=true <image>@<digest>`
4. If the signature is valid but Kyverno still denies: check Kyverno can reach the registry
   (`registry-pull` secret in `kyverno`, lab CA mounted, CoreDNS forwarding for `securestream.lab`).

## Never
Do not disable the policy or switch it to `Audit` to "make it work". An unexpected unsigned image in
production is a potential incident: treat it as one until proven otherwise.
