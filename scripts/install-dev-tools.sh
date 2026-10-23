#!/usr/bin/env bash
# ss-mgmt yerel lint araclari (push oncesi kontrol): shellcheck. Kullanici dizinine (~/.local/bin), sabit surum,
# GitHub release varliginin SHA256'si ile dogrulanir; sudo gerekmez. Tekrar calistirmak guvenlidir.
# Not: ~/.local/bin PATH'te once gelir; buraya yalnizca bu betigin dogruladigi araclar konur, izinli betik
# adlari (ci-status) asla (CLAUDE.md kural 7).
set -euo pipefail
SHELLCHECK_VERSION=v0.11.0
SHELLCHECK_SHA256=b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6
BIN=$HOME/.local/bin
fail() { echo "HATA: $*" >&2; exit 1; }
mkdir -p "$BIN"
if [[ $("$BIN/shellcheck" --version 2>/dev/null | sed -n 's/^version: //p') == "${SHELLCHECK_VERSION#v}" ]]; then
  echo "OK  shellcheck $SHELLCHECK_VERSION zaten kurulu"
  exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
F=shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.gz
curl -fsSL --proto '=https' -o "$TMP/$F" "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/$F"
echo "$SHELLCHECK_SHA256  $TMP/$F" | sha256sum -c --status || fail "shellcheck SHA256 uyusmuyor"
tar -xzf "$TMP/$F" -C "$TMP"
install -m 0755 "$TMP/shellcheck-${SHELLCHECK_VERSION}/shellcheck" "$BIN/shellcheck"
echo "OK  shellcheck $("$BIN/shellcheck" --version | sed -n 's/^version: //p') -> $BIN/shellcheck"
