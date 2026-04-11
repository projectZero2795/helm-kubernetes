#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TIMEOUT="${HELM_TIMEOUT:-15m0s}"
HELM_WORKDIR="${ROOT_DIR}/.tmp/helm"

export HELM_CONFIG_HOME="${HELM_CONFIG_HOME:-${HELM_WORKDIR}/config}"
export HELM_CACHE_HOME="${HELM_CACHE_HOME:-${HELM_WORKDIR}/cache}"
export HELM_DATA_HOME="${HELM_DATA_HOME:-${HELM_WORKDIR}/data}"

mkdir -p "$HELM_CONFIG_HOME" "$HELM_CACHE_HOME" "$HELM_DATA_HOME"

require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
}

ensure_repo() {
  local name="$1"
  local url="$2"
  helm repo add "$name" "$url" >/dev/null 2>&1 || true
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/helm.sh deps [all|monitoring|networking]
  ./scripts/helm.sh lint [all|monitoring|networking]
  ./scripts/helm.sh template [all|monitoring|networking]
  ./scripts/helm.sh deploy [all|monitoring|networking]
EOF
}

targets_for() {
  local selector="${1:-all}"
  case "$selector" in
    all)
      printf '%s\n' monitoring networking
      ;;
    monitoring|networking)
      printf '%s\n' "$selector"
      ;;
    *)
      echo "unknown target: $selector" >&2
      usage
      exit 1
      ;;
  esac
}

chart_dir() {
  printf '%s/functions/%s' "$ROOT_DIR" "$1"
}

namespace_for() {
  case "$1" in
    monitoring)
      printf '%s' monitoring
      ;;
    networking)
      printf '%s' networking
      ;;
  esac
}

set_context() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    kubectl config use-context "$KUBE_CONTEXT" >/dev/null
  fi
}

run_deps() {
  ensure_repo traefik https://traefik.github.io/charts

  local target
  while IFS= read -r target; do
    helm dependency build "$(chart_dir "$target")"
  done < <(targets_for "${1:-all}")
}

run_lint() {
  local target
  while IFS= read -r target; do
    helm lint "$(chart_dir "$target")"
  done < <(targets_for "${1:-all}")
}

run_template() {
  local target
  while IFS= read -r target; do
    helm template \
      "$target" \
      "$(chart_dir "$target")" \
      --namespace "$(namespace_for "$target")" \
      >/dev/null
  done < <(targets_for "${1:-all}")
}

deploy_target() {
  local target="$1"

  helm upgrade --install \
    "$target" \
    "$(chart_dir "$target")" \
    --namespace "$(namespace_for "$target")" \
    --create-namespace \
    --wait \
    --atomic \
    --timeout "$DEFAULT_TIMEOUT" \
    --history-max 10
}

run_deploy() {
  set_context
  kubectl cluster-info >/dev/null

  local target
  while IFS= read -r target; do
    deploy_target "$target"
  done < <(targets_for "${1:-all}")
}

main() {
  local command="${1:-}"
  local selector="${2:-all}"

  case "$command" in
    deps)
      require_tool helm
      run_deps "$selector"
      ;;
    lint)
      require_tool helm
      run_lint "$selector"
      ;;
    template)
      require_tool helm
      run_template "$selector"
      ;;
    deploy)
      require_tool helm
      require_tool kubectl
      run_deploy "$selector"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
