#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TIMEOUT="${HELM_TIMEOUT:-15m0s}"
HELM_WORKDIR="${ROOT_DIR}/.tmp/helm"

export PATH="${HOME}/.local/bin:${PATH}"
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
  ./scripts/helm.sh deps [all|storage|monitoring|networking]
  ./scripts/helm.sh lint [all|storage|monitoring|networking]
  ./scripts/helm.sh template [all|storage|monitoring|networking]
  ./scripts/helm.sh deploy [all|storage|monitoring|networking]
EOF
}

targets_for() {
  local selector="${1:-all}"
  case "$selector" in
    all)
      printf '%s\n' storage monitoring networking
      ;;
    storage|monitoring|networking)
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
    storage)
      printf '%s' local-path-storage
      ;;
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

run_upgrade_install() {
  local target="$1"
  local namespace="$2"

  helm upgrade --install \
    "$target" \
    "$(chart_dir "$target")" \
    --namespace "$namespace" \
    --create-namespace \
    --wait \
    --atomic \
    --timeout "$DEFAULT_TIMEOUT" \
    --history-max 10
}

release_status() {
  local target="$1"
  local namespace="$2"

  helm status "$target" --namespace "$namespace" 2>/dev/null | awk '/^STATUS:/ {print $2; exit}'
}

last_deployed_revision() {
  local target="$1"
  local namespace="$2"

  helm history "$target" --namespace "$namespace" 2>/dev/null | awk 'NR > 1 && $3 == "deployed" {rev=$1} END {print rev}'
}

wait_for_release_absent() {
  local target="$1"
  local namespace="$2"
  local attempt

  for attempt in $(seq 1 20); do
    if ! helm status "$target" --namespace "$namespace" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done

  echo "Timed out waiting for release $target in namespace $namespace to disappear from Helm state." >&2
  return 1
}

recover_locked_release() {
  local target="$1"
  local namespace="$2"
  local status
  local deployed_revision

  status="$(release_status "$target" "$namespace")"

  case "$status" in
    pending-install)
      echo "Release $target in namespace $namespace is stuck in pending-install. Uninstalling the failed release before retry." >&2
      helm uninstall "$target" --namespace "$namespace" --wait --ignore-not-found >&2
      wait_for_release_absent "$target" "$namespace"
      ;;
    pending-upgrade|pending-rollback)
      deployed_revision="$(last_deployed_revision "$target" "$namespace")"
      if [[ -n "$deployed_revision" ]]; then
        echo "Release $target in namespace $namespace is stuck in $status. Rolling back to deployed revision $deployed_revision before retry." >&2
        helm rollback "$target" "$deployed_revision" --namespace "$namespace" --wait >&2
      else
        echo "Release $target in namespace $namespace is stuck in $status with no deployed revision. Uninstalling before retry." >&2
        helm uninstall "$target" --namespace "$namespace" --wait --ignore-not-found >&2
        wait_for_release_absent "$target" "$namespace"
      fi
      ;;
    *)
      echo "Release $target in namespace $namespace is locked, but Helm reports status '${status:-unknown}'. Refusing automatic recovery." >&2
      return 1
      ;;
  esac
}

deploy_target() {
  local target="$1"
  local namespace
  local output
  local retry

  namespace="$(namespace_for "$target")"

  if output="$(run_upgrade_install "$target" "$namespace" 2>&1)"; then
    printf '%s\n' "$output"
    return 0
  fi

  printf '%s\n' "$output" >&2

  if [[ "$output" == *"has no deployed releases"* ]]; then
    echo "Release $target in namespace $namespace has no deployed revision. Cleaning up failed bootstrap release and retrying once." >&2
    helm uninstall "$target" --namespace "$namespace" --wait --ignore-not-found >&2
    wait_for_release_absent "$target" "$namespace"
    run_upgrade_install "$target" "$namespace"
    return 0
  fi

  if [[ "$output" == *"another operation (install/upgrade/rollback) is in progress"* ]]; then
    for retry in 1 2 3; do
      echo "Release $target in namespace $namespace is locked by another Helm operation. Waiting 15 seconds before retry $retry/3." >&2
      sleep 15
      if output="$(run_upgrade_install "$target" "$namespace" 2>&1)"; then
        printf '%s\n' "$output"
        return 0
      fi
      printf '%s\n' "$output" >&2
      if [[ "$output" != *"another operation (install/upgrade/rollback) is in progress"* ]]; then
        break
      fi
    done

    if [[ "$output" == *"another operation (install/upgrade/rollback) is in progress"* ]]; then
      recover_locked_release "$target" "$namespace"
      run_upgrade_install "$target" "$namespace"
      return 0
    fi
  fi

  if [[ "$output" == *"original install error:"* && "$output" == *"uninstallation completed with"* ]]; then
    echo "Helm left release $target in namespace $namespace in an inconsistent post-install cleanup state. Waiting for release metadata to clear, then retrying once." >&2
    helm uninstall "$target" --namespace "$namespace" --wait --ignore-not-found >/dev/null 2>&1 || true
    wait_for_release_absent "$target" "$namespace"
    run_upgrade_install "$target" "$namespace"
    return 0
  fi

  return 1
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
