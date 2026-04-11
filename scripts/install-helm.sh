#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HELM_INSTALL_DIR:-$HOME/.local/bin}"
export PATH="${INSTALL_DIR}:${PATH}"

if command -v helm >/dev/null 2>&1; then
  echo "helm already installed: $(helm version --short)"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to install helm" >&2
  exit 1
fi

TMP_SCRIPT="$(mktemp)"
trap 'rm -f "$TMP_SCRIPT"' EXIT

mkdir -p "$INSTALL_DIR"
curl -fsSL -o "$TMP_SCRIPT" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 "$TMP_SCRIPT"

export HELM_INSTALL_DIR="$INSTALL_DIR"
"$TMP_SCRIPT"

if [[ -x "$INSTALL_DIR/helm" ]]; then
  echo "helm installed to $INSTALL_DIR"
  "$INSTALL_DIR/helm" version --short
  exit 0
fi

echo "helm installation completed, but the binary was not found in $INSTALL_DIR" >&2
exit 1
