# Platform security expansion — progress

Brief: `docs/tasks/platform-security-expansion.md` (kept local). One row per item, appended when the item is done.

| Item | Status | Commit | Evidence |
|---|---|---|---|
| 0 Housekeeping | Done | `docs: gunluk.md engineering-log.md olarak yeniden adlandirildi` | `git log --follow docs/engineering-log.md` shows full history; `grep -rn gunluk.md` → no references; no personal wording left except authorship (LICENSE, GitHub URLs) |
| 1 Capacity check | Done (no resize needed) | `feat: pve1 kapasite betigi (salt okunur, Proxmox API)` | See capacity report below |

### Capacity report (2026-10-23)

| Resource | Requirement | Measured | Result |
|---|---|---|---|
| ss-sec RAM | ≥ 10 GB | 16 GiB in Terraform (`vms.tf`), `free -h`: 15 Gi total, 15 Gi available | OK |
| ss-sec vCPU | ≥ 4 | 8 (`nproc`) | OK |
| ss-sec disk | ≥ 60 GB | 120 GB in Terraform, `/` 116 G, 114 G free | OK |
| k3s free RAM for monitoring | ~3 GB | `kubectl top nodes`: cp 1.7/7.8 GiB, w1 0.8/15.6 GiB, w2 0.8/15.6 GiB used | OK (~35 GiB free) |
| pve1 storage | — | `local-lvm` 724 GiB free of 793, `local` 80 GiB free | OK |
| pve1 RAM / CPU totals | — | Not readable: the `terraform@pve` token has no `Sys.Audit` (HTTP 403). VMs allocated: 54 vCPU, 95 GiB RAM (all running) | **Human check:** read pve1 total RAM in the Proxmox UI; no new VM is added, so the plan does not raise the allocation |

Decision: no `tf.sh apply` needed. Items 4 and 5 run inside the existing ss-sec VM, Item 9 inside the existing k3s nodes.
Order kept as in the brief. Docker is not yet installed on ss-sec (Item 4 `appsec_host` installs it).
