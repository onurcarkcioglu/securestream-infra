#!/usr/bin/env python3
"""NetworkPolicy manifestlerini canli pod'larla karsilastirir (salt okunur; claude-readonly ile de calisir).

Hata: bir izin politikasinin podSelector'u hic pod secmiyor, izin verilen port hedef pod'da yok (adli ya da
numarali), ya da namespace/pod kaynak secicisi hic pod secmiyor. default-deny ile birlikte bu hatalar trafigi
sessizce keser.
Kullanim: netpol-check.py <manifest.yaml>...   (exit 1 = sorun)
"""
import json
import subprocess
import sys

import yaml


def running_pods(ns, selector=None):
    out = subprocess.run(["kubectl", "-n", ns, "get", "pods", "-o", "json"], capture_output=True, text=True, check=True)
    result = []
    for pod in json.loads(out.stdout)["items"]:
        if pod["status"].get("phase") != "Running":
            continue
        labels = pod["metadata"].get("labels", {})
        sel = selector or {}
        if any(labels.get(k) != v for k, v in (sel.get("matchLabels") or {}).items()):
            continue
        if any(e["operator"] == "In" and labels.get(e["key"]) not in e["values"] for e in sel.get("matchExpressions") or []):
            continue
        result.append(pod)
    return result


def pod_ports(pod):
    ports = [p for c in pod["spec"]["containers"] for p in c.get("ports", [])]
    return {p.get("name") for p in ports}, {p["containerPort"] for p in ports}


def main(paths):
    problems = 0
    for path in paths:
        for doc in yaml.safe_load_all(open(path)):
            if not doc or doc.get("kind") != "NetworkPolicy":
                continue
            ns, name = doc["metadata"]["namespace"], doc["metadata"]["name"]
            rules = doc["spec"].get("ingress", [])
            targets = running_pods(ns, doc["spec"]["podSelector"])
            notes = []
            if rules and not targets:
                notes.append("HATA: hedef pod yok")
                problems += 1
            for rule in rules:
                for port in (p["port"] for p in rule.get("ports", [])):
                    for pod in targets:
                        names, numbers = pod_ports(pod)
                        if port not in (names if isinstance(port, str) else numbers):
                            notes.append(f"HATA: port {port} yok ({pod['metadata']['name']})")
                            problems += 1
                for src in rule.get("from", []):
                    if "ipBlock" in src:
                        continue
                    src_ns = (src.get("namespaceSelector") or {}).get("matchLabels", {}).get("kubernetes.io/metadata.name", ns)
                    count = len(running_pods(src_ns, src.get("podSelector")))
                    notes.append(f"kaynak {src_ns}: {count} pod")
                    if count == 0:
                        notes.append("HATA: kaynak secici pod secmiyor")
                        problems += 1
            print(f"{ns:16} {name:36} hedef={len(targets):<2} {'; '.join(notes)}")
    print(f"{problems} sorun")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
