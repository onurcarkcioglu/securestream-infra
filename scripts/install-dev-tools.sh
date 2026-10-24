#!/usr/bin/env bash
# ss-mgmt yerel lint/test araclari (push oncesi kontrol): shellcheck, promtool. Kullanici dizinine (~/.local/bin),
# sabit surum, GitHub release varliginin SHA256'si ile dogrulanir; sudo gerekmez. Tekrar calistirmak guvenlidir.
# Not: ~/.local/bin PATH'te once gelir; buraya yalnizca bu betigin dogruladigi araclar konur, izinli betik
# adlari (ci-status) asla (CLAUDE.md kural 7).
set -euo pipefail
SHELLCHECK_VERSION=v0.11.0
SHELLCHECK_SHA256=b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6
# promtool: kumedeki Prometheus ile ayni surum (kube-prometheus-stack 92.2.0 -> Prometheus v3.15.0)
PROMETHEUS_VERSION=3.15.0
PROMETHEUS_SHA256=2a542df32eac02ee17b9d844fb2aa1de00dafa5476579ba8a3ba862e9d572ea0
BIN=$HOME/.local/bin
fail() { echo "HATA: $*" >&2; exit 1; }
mkdir -p "$BIN"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# indir <url> <sha256> <dosya>: SHA256 uyusmazsa durur
fetch() {
  curl -fsSL --proto '=https' -o "$TMP/$3" "$1"
  echo "$2  $TMP/$3" | sha256sum -c --status || fail "$3 SHA256 uyusmuyor"
}

if [[ $("$BIN/shellcheck" --version 2>/dev/null | sed -n 's/^version: //p') == "${SHELLCHECK_VERSION#v}" ]]; then
  echo "OK  shellcheck $SHELLCHECK_VERSION zaten kurulu"
else
  F=shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.gz
  fetch "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/$F" "$SHELLCHECK_SHA256" "$F"
  tar -xzf "$TMP/$F" -C "$TMP"
  install -m 0755 "$TMP/shellcheck-${SHELLCHECK_VERSION}/shellcheck" "$BIN/shellcheck"
  echo "OK  shellcheck $("$BIN/shellcheck" --version | sed -n 's/^version: //p') -> $BIN/shellcheck"
fi

if "$BIN/promtool" --version 2>/dev/null | grep -q "^promtool, version ${PROMETHEUS_VERSION} "; then
  echo "OK  promtool $PROMETHEUS_VERSION zaten kurulu"
else
  F=prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
  fetch "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/$F" "$PROMETHEUS_SHA256" "$F"
  tar -xzf "$TMP/$F" -C "$TMP" "prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool"
  install -m 0755 "$TMP/prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool" "$BIN/promtool"
  echo "OK  $("$BIN/promtool" --version | head -1) -> $BIN/promtool"
fi
