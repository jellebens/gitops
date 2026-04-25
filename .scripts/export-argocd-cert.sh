#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-argocd}"
SECRET_NAME="${2:-argocd-server-tls}"
OUT_DIR="${3:-./.tmp/certs}"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
}

extract_key() {
  local key="$1"
  local outfile="$2"
  kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o go-template="{{index .data \"$key\"}}" | base64 -d > "$outfile"
}

require_cmd kubectl
require_cmd base64
require_cmd openssl

mkdir -p "$OUT_DIR"

CA_FILE="$OUT_DIR/argocd-ca.crt"
TLS_FILE="$OUT_DIR/argocd-tls.crt"
KEY_FILE="$OUT_DIR/argocd-tls.key"

extract_key "ca.crt" "$CA_FILE"
extract_key "tls.crt" "$TLS_FILE"
extract_key "tls.key" "$KEY_FILE"

if [[ ! -s "$CA_FILE" || ! -s "$TLS_FILE" || ! -s "$KEY_FILE" ]]; then
  echo "Error: one or more exported files are empty" >&2
  exit 1
fi

echo "Exported certificate files:"
echo "  $CA_FILE"
echo "  $TLS_FILE"
echo "  $KEY_FILE"

echo
echo "File sizes (bytes):"
wc -c "$CA_FILE" "$TLS_FILE" "$KEY_FILE"

echo
echo "Certificate summary (CA cert):"
openssl x509 -in "$CA_FILE" -noout -subject -issuer -dates -fingerprint -sha256

echo
echo "Windows trust command (run in elevated PowerShell):"
echo "  certutil -addstore -f Root <path-to-argocd-ca.crt>"
