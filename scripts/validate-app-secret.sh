#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="openstudio-server"
SECRET_NAME="openstudio-app-secrets"
DB_USERNAME_KEY="${SECRET_KEY_DB_USERNAME:-db-username}"
DB_PASSWORD_KEY="${SECRET_KEY_DB_PASSWORD:-db-password}"
REDIS_PASSWORD_KEY="${SECRET_KEY_REDIS_PASSWORD:-redis-password}"
WEB_SECRET_KEY="${SECRET_KEY_WEB_SECRET:-web-secret-key}"

usage() {
  cat <<'EOF'
Usage: validate-app-secret.sh [--namespace <namespace>] [--secret-name <name>]

Validates that an existing Kubernetes secret contains all required OpenStudio app keys
with non-empty values.

Required keys (customizable via environment variables):
  SECRET_KEY_DB_USERNAME   (default: db-username)
  SECRET_KEY_DB_PASSWORD   (default: db-password)
  SECRET_KEY_REDIS_PASSWORD(default: redis-password)
  SECRET_KEY_WEB_SECRET    (default: web-secret-key)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --secret-name)
      SECRET_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required to validate existing secrets." >&2
  exit 1
fi

if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Required secret '$SECRET_NAME' was not found in namespace '$NAMESPACE'." >&2
  exit 1
fi

decode_base64() {
  local input="$1"
  if decoded=$(printf '%s' "$input" | base64 --decode 2>/dev/null); then
    printf '%s' "$decoded"
    return 0
  fi

  if decoded=$(printf '%s' "$input" | base64 -D 2>/dev/null); then
    printf '%s' "$decoded"
    return 0
  fi

  return 1
}

missing_keys=()
empty_keys=()
required_keys=("$DB_USERNAME_KEY" "$DB_PASSWORD_KEY" "$REDIS_PASSWORD_KEY" "$WEB_SECRET_KEY")

for key in "${required_keys[@]}"; do
  encoded="$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o "jsonpath={.data['$key']}" 2>/dev/null || true)"
  if [[ -z "$encoded" || "$encoded" == "<no value>" ]]; then
    missing_keys+=("$key")
    continue
  fi

  decoded="$(decode_base64 "$encoded" || true)"
  if [[ -z "$decoded" ]]; then
    empty_keys+=("$key")
  fi
done

if (( ${#missing_keys[@]} > 0 )); then
  echo "Secret '$SECRET_NAME' in namespace '$NAMESPACE' is missing required keys: ${missing_keys[*]}" >&2
  exit 1
fi

if (( ${#empty_keys[@]} > 0 )); then
  echo "Secret '$SECRET_NAME' in namespace '$NAMESPACE' has empty values for keys: ${empty_keys[*]}" >&2
  exit 1
fi

echo "Secret '$SECRET_NAME' in namespace '$NAMESPACE' contains required non-empty keys."
