#!/usr/bin/env python3
"""Render edilmis platform chart'larini iki kurala gore denetler (platform-render-check.sh cagirir).

1. Her is yuku konteynerinde (init ve Job dahil) cpu ve memory icin istek ve limit var (Kubescape C-0270/C-0271).
2. Her pod, namespace'inin Pod Security Admission enforce seviyesini karsilar; etiketsiz namespace hata.

Kullanim: platform-render-check.py <namespace-manifest>... -- <rendered.yaml>...
"""
import sys

import yaml

BASELINE_CAPS = {"AUDIT_WRITE", "CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "MKNOD", "NET_BIND_SERVICE",
                 "SETFCAP", "SETGID", "SETPCAP", "SETUID", "SYS_CHROOT"}
WORKLOADS = {"Deployment", "DaemonSet", "StatefulSet", "Job", "CronJob"}
LEVELS = {"privileged": 0, "baseline": 1, "restricted": 2}


def namespace_levels(paths):
    levels = {}
    for path in paths:
        for doc in yaml.safe_load_all(open(path)):
            if doc and doc.get("kind") == "Namespace":
                labels = doc["metadata"].get("labels") or {}
                levels[doc["metadata"]["name"]] = labels.get("pod-security.kubernetes.io/enforce")
    return levels


def pod_template(doc):
    if doc["kind"] == "CronJob":
        return doc["spec"]["jobTemplate"]["spec"]["template"]
    return doc["spec"]["template"]


def violations(template):
    """PSA ihlallerini seviyeye gore dondurur: {'baseline': [...], 'restricted': [...]}."""
    spec, meta = template["spec"], template.get("metadata") or {}
    base, restr = [], []
    for key in ("hostNetwork", "hostPID", "hostIPC"):
        if spec.get(key):
            base.append(key)
    base += [f"hostPath {v['hostPath']['path']}" for v in spec.get("volumes") or [] if "hostPath" in v]
    for name, value in (meta.get("annotations") or {}).items():
        if name.startswith("container.apparmor.security.beta.kubernetes.io/") and value == "unconfined":
            base.append("apparmor unconfined")
    pod_sc = spec.get("securityContext") or {}
    for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
        sc, n = c.get("securityContext") or {}, c["name"]
        caps = sc.get("capabilities") or {}
        if sc.get("privileged"):
            base.append(f"{n}: privileged")
        extra = set(caps.get("add") or []) - BASELINE_CAPS
        if extra:
            base.append(f"{n}: capabilities {sorted(extra)}")
        if any(p.get("hostPort") for p in c.get("ports") or []):
            base.append(f"{n}: hostPort")
        if not sc.get("runAsNonRoot", pod_sc.get("runAsNonRoot")):
            restr.append(f"{n}: runAsNonRoot")
        if sc.get("allowPrivilegeEscalation") is not False:
            restr.append(f"{n}: allowPrivilegeEscalation")
        if "ALL" not in (caps.get("drop") or []):
            restr.append(f"{n}: capabilities.drop ALL")
        if set(caps.get("add") or []) - {"NET_BIND_SERVICE"}:
            restr.append(f"{n}: capabilities.add")
        seccomp = (sc.get("seccompProfile") or pod_sc.get("seccompProfile") or {}).get("type")
        if seccomp not in ("RuntimeDefault", "Localhost"):
            restr.append(f"{n}: seccompProfile")
    return {"baseline": base, "restricted": base + restr}


def missing_resources(template):
    spec, out = template["spec"], []
    for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
        res = c.get("resources") or {}
        out += [f"{c['name']}: {kind}.{r}" for kind in ("requests", "limits") for r in ("cpu", "memory")
                if not (res.get(kind) or {}).get(r)]
    return out


def main(argv):
    sep = argv.index("--")
    levels, rendered = namespace_levels(argv[:sep]), argv[sep + 1:]
    errors, checked = [], 0
    for path in rendered:
        for doc in yaml.safe_load_all(open(path)):
            if not doc or doc.get("kind") not in WORKLOADS:
                continue
            if doc["kind"] != "CronJob" and doc["spec"].get("replicas") == 0:
                continue
            checked += 1
            ns, ref = doc["metadata"].get("namespace", "?"), f"{doc['kind']} {doc['metadata'].get('namespace')}/{doc['metadata']['name']}"
            template = pod_template(doc)
            for item in missing_resources(template):
                errors.append(f"{ref}: istek/limit eksik: {item}")
            level = levels.get(ns)
            if level is None:
                errors.append(f"{ref}: namespace '{ns}' icin PSA enforce etiketi yok")
                continue
            if LEVELS[level] > 0:
                for item in violations(template)[level]:
                    errors.append(f"{ref}: PSA {level} ihlali: {item}")
    for e in errors:
        print("HATA:", e)
    print(f"{checked} is yuku denetlendi, {len(errors)} hata")
    return 1 if errors or checked == 0 else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
