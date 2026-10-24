#!/usr/bin/env python3
"""kube-bench JSON raporunu dugumde temizler (playbooks/kube-bench.yml calistirir).

Izin listesi: yalnizca benchmark metni ve sonuc kalir. Denetim komutlari ve ciktilari (audit, AuditConfig,
AuditEnv, actual_value, reason) atilir: journal satirlari, yapilandirma dosyasi icerigi ve komut satirlari dugumden
cikmaz. Kullanim: kube-bench-sanitize.py <ham.json> <temiz.json> <dugum-adi>
"""
import json
import sys

RESULT_KEYS = {"test_number", "test_desc", "remediation", "status", "scored", "type", "test_info", "expected_result"}
TEST_KEYS = {"section", "type", "pass", "fail", "warn", "info", "desc"}
CONTROL_KEYS = {"id", "version", "detected_version", "text", "node_type", "total_pass", "total_fail", "total_warn",
                "total_info"}


def main(src, dst, node):
    raw = json.load(open(src))
    controls = raw["Controls"] if isinstance(raw, dict) else raw
    clean = []
    for control in controls:
        c = {k: v for k, v in control.items() if k in CONTROL_KEYS}
        c["tests"] = []
        for test in control.get("tests") or []:
            t = {k: v for k, v in test.items() if k in TEST_KEYS}
            t["results"] = [{k: v for k, v in r.items() if k in RESULT_KEYS} for r in test.get("results") or []]
            c["tests"].append(t)
        clean.append(c)
    out = {"node": node, "Controls": clean}
    if isinstance(raw, dict) and "Totals" in raw:
        out["Totals"] = raw["Totals"]
    json.dump(out, open(dst, "w"), indent=1)


if __name__ == "__main__":
    main(*sys.argv[1:4])
