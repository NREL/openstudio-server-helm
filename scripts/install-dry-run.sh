#!/usr/bin/env bash
set -euo pipefail

# Validate chart rendering across provider matrix, OpenStack overlays, and secret modes.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${ROOT_DIR}/openstudio-server"

helm lint "${CHART_DIR}" --set global.provider.name=aws --set secrets.validateExistingSecret=false >/dev/null
helm template openstudio-server "${CHART_DIR}" --set global.provider.name=aws --set secrets.validateExistingSecret=false >/dev/null
helm template openstudio-server "${CHART_DIR}" --set global.provider.name=google --set secrets.validateExistingSecret=false >/dev/null
helm template openstudio-server "${CHART_DIR}" --set global.provider.name=azure --set secrets.validateExistingSecret=false >/dev/null
helm template openstudio-server "${CHART_DIR}" --set global.provider.name=openstack --set secrets.validateExistingSecret=false >/dev/null
helm template openstudio-server "${CHART_DIR}" -f "${ROOT_DIR}/openstack/values-openstack.yaml" --set secrets.validateExistingSecret=false >/dev/null
helm template openstudio-server "${CHART_DIR}" -f "${ROOT_DIR}/openstack/values-openstack-nfs.yaml" --set secrets.validateExistingSecret=false >/dev/null
helm template openstudio-server "${CHART_DIR}" -f "${ROOT_DIR}/openstack/values-openstack-nfs-small.yaml" --set secrets.validateExistingSecret=false >/dev/null
helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=openstack \
  --set secrets.validateExistingSecret=false \
  --set autoscaler.enabled=true \
  --set autoscaler.openstack.checkExistingDeploymentOwnership=false \
  --set autoscaler.openstack.cloudConfigSecretName=cloud-config \
  --set autoscaler.openstackNodeGroups[0].name=worker \
  --set autoscaler.openstackNodeGroups[0].min=1 \
  --set autoscaler.openstackNodeGroups[0].max=5 >/dev/null
helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=openstack \
  --set secrets.validateExistingSecret=false \
  --set autoscaler.enabled=true \
  --set autoscaler.openstack.checkExistingDeploymentOwnership=false \
  --set autoscaler.openstack.cloudConfigSecretName=cloud-config \
  --set autoscaler.openstack.caBundleSecretName=openstack-api-ca \
  --set autoscaler.openstackNodeGroups[0].name=worker \
  --set autoscaler.openstackNodeGroups[0].min=1 \
  --set autoscaler.openstackNodeGroups[0].max=5 >/dev/null
helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=aws \
  --set secrets.validateExistingSecret=false \
  --set secrets.existingSecret= \
  --set secrets.create=true \
  --set db.username=chart-user \
  --set db.password=chart-pass \
  --set redis.password=chart-pass \
  --set web.secret_key_value=chart-secret >/dev/null

if helm template openstudio-server "${CHART_DIR}" >/dev/null 2>&1; then
  echo "Expected failure when global.provider.name is unset"
  exit 1
fi

if helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=aws >/dev/null 2>&1; then
  echo "Expected failure when secrets.validateExistingSecret defaults to true without a live cluster Secret"
  exit 1
fi

if helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=aws \
  --set secrets.validateExistingSecret=false \
  --set secrets.create=true >/dev/null 2>&1; then
  echo "Expected failure when secrets.create=true and required credential values are missing"
  exit 1
fi

if helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=aws \
  --set secrets.validateExistingSecret=false \
  --set secrets.existingSecret=openstudio-app-secrets \
  --set secrets.create=true >/dev/null 2>&1; then
  echo "Expected failure when secrets.existingSecret and secrets.create=true are both set"
  exit 1
fi

if helm template openstudio-server "${CHART_DIR}" \
  -f "${ROOT_DIR}/openstack/values-openstack.yaml" >/dev/null 2>&1; then
  echo "Expected failure when OpenStack values enable secrets.validateExistingSecret without a live cluster Secret"
  exit 1
fi

if helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=openstack \
  --set secrets.validateExistingSecret=false \
  --set autoscaler.enabled=true \
  --set autoscaler.openstackNodeGroups[0].name=worker \
  --set autoscaler.openstackNodeGroups[0].min=1 \
  --set autoscaler.openstackNodeGroups[0].max=5 >/dev/null 2>&1; then
  echo "Expected failure when OpenStack autoscaler is enabled without cloud config input"
  exit 1
fi

helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=aws \
  --set secrets.validateExistingSecret=false \
  --set db.name=custom-db \
  --set redis.name=custom-redis \
  --set nfs_pvc.name=custom-nfs-pvc \
  --set load_balancer.name=custom-lb \
  --set load_balancer.ports.http_port=8080 \
  --set load_balancer.ports.https_port=8443 >/dev/null

if helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=aws \
  --set secrets.validateExistingSecret=false \
  --set provider.name=aws >/dev/null 2>&1; then
  echo "Expected failure when deprecated provider.name is set"
  exit 1
fi

helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name= \
  --set global.provider.allowLegacyName=true \
  --set secrets.validateExistingSecret=false \
  --set provider.name=aws >/dev/null

if ! helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=aws \
  --set secrets.validateExistingSecret=false \
  --set redis.url='redis://:pa%40ss@custom-redis:6380/0' \
  | grep -q 'value: "redis://:pa%40ss@custom-redis:6380/0"'; then
  echo "Expected redis.url override to render into REDIS_URL env values"
  exit 1
fi

if ! helm template openstudio-server "${CHART_DIR}" \
  -f "${ROOT_DIR}/openstack/values-openstack.yaml" \
  --set secrets.validateExistingSecret=false \
  | grep -q 'storageClassName: "csi-cinder"'; then
  echo "Expected OpenStack values to render csi-cinder as NFS provisioner backing storageClass"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat > "${TMP_DIR}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_KUBECTL_LOG:-}" ]]; then
  echo "$*" >> "${MOCK_KUBECTL_LOG}"
fi

if [[ "${1:-}" == "get" && "${2:-}" == "namespace" ]]; then
  if [[ "${MOCK_NAMESPACE_MISSING:-false}" == "true" ]]; then
    exit 1
  fi
  exit 0
fi

if [[ "${1:-}" == "create" && "${2:-}" == "namespace" ]]; then
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "secret" ]]; then
  secret_name="$3"
  if [[ "${MOCK_SECRET_STATE:-present}" == "missing" || "${secret_name}" != "openstudio-app-secrets" ]]; then
    exit 1
  fi

  if [[ "${7:-}" == "jsonpath={.data['db-username']}" ]]; then
    if [[ "${MOCK_SECRET_STATE:-present}" == "missing-db-username" ]]; then
      printf ''
    else
      printf 'b3BlbnN0dWRpbw=='
    fi
    exit 0
  fi
  if [[ "${7:-}" == "jsonpath={.data['db-password']}" ]]; then
    printf 'Y2hhcnQtcGFzcw=='
    exit 0
  fi
  if [[ "${7:-}" == "jsonpath={.data['redis-password']}" ]]; then
    printf 'Y2hhcnQtcGFzcw=='
    exit 0
  fi
  if [[ "${7:-}" == "jsonpath={.data['web-secret-key']}" ]]; then
    printf 'Y2hhcnQtc2VjcmV0'
    exit 0
  fi

  exit 0
fi

exit 1
EOF
chmod +x "${TMP_DIR}/kubectl"

cat > "${TMP_DIR}/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_HELM_LOG:-}" ]]; then
  echo "$*" >> "${MOCK_HELM_LOG}"
fi

for secret in "${DB_USERNAME:-}" "${DB_PASSWORD:-}" "${REDIS_PASSWORD:-}" "${WEB_SECRET_KEY:-}"; do
  if [[ -n "${secret}" && "$*" == *"$secret"* ]]; then
    echo "Secret value leaked into Helm CLI args" >&2
    exit 1
  fi
done

values_file=""
args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" == "--values" ]]; then
    values_file="${args[$((i + 1))]}"
    break
  fi
done

if [[ -n "${EXPECT_VALUES_FILE:-}" ]]; then
  if [[ -z "${values_file}" || ! -f "${values_file}" ]]; then
    echo "Expected install.sh to pass a --values file for secrets.create mode" >&2
    exit 1
  fi
  if ! grep -Fq "username: 'open''studio'" "${values_file}"; then
    echo "Expected escaped username in generated values file" >&2
    exit 1
  fi
  if ! grep -Fq "password: 'abc,def''ghi'" "${values_file}"; then
    echo "Expected escaped db password in generated values file" >&2
    exit 1
  fi
  if ! grep -Fq "password: 'redis,pass'" "${values_file}"; then
    echo "Expected redis password in generated values file" >&2
    exit 1
  fi
  if ! grep -Fq "secret_key_value: 'secret''key,123'" "${values_file}"; then
    echo "Expected escaped web secret in generated values file" >&2
    exit 1
  fi
fi
EOF
chmod +x "${TMP_DIR}/helm"

if PATH="${TMP_DIR}:${PATH}" MOCK_SECRET_STATE=missing "${ROOT_DIR}/scripts/validate-app-secret.sh" --namespace openstudio-server --secret-name openstudio-app-secrets >/dev/null 2>&1; then
  echo "Expected secret validator to fail when secret is missing"
  exit 1
fi

if PATH="${TMP_DIR}:${PATH}" MOCK_SECRET_STATE=missing-db-username "${ROOT_DIR}/scripts/validate-app-secret.sh" --namespace openstudio-server --secret-name openstudio-app-secrets >/dev/null 2>&1; then
  echo "Expected secret validator to fail when required keys are missing"
  exit 1
fi

if ! PATH="${TMP_DIR}:${PATH}" MOCK_SECRET_STATE=present "${ROOT_DIR}/scripts/validate-app-secret.sh" --namespace openstudio-server --secret-name openstudio-app-secrets >/dev/null; then
  echo "Expected secret validator to pass when required keys are present"
  exit 1
fi

MOCK_HELM_LOG="${TMP_DIR}/helm.log"
MOCK_KUBECTL_LOG="${TMP_DIR}/kubectl.log"

if ! PATH="${TMP_DIR}:${PATH}" \
  EXPECT_VALUES_FILE=true \
  HELM_DEBUG=false \
  PROVIDER=aws \
  SECRET_MODE=create \
  DB_USERNAME="open'studio" \
  DB_PASSWORD="abc,def'ghi" \
  REDIS_PASSWORD="redis,pass" \
  WEB_SECRET_KEY="secret'key,123" \
  RELEASE_NAME=openstudio-server \
  NAMESPACE=openstudio-server \
  CHART_PATH="${CHART_DIR}" \
  MOCK_HELM_LOG="${MOCK_HELM_LOG}" \
  "${ROOT_DIR}/scripts/install.sh" >/dev/null; then
  echo "Expected install.sh create mode to succeed with special-character secrets"
  exit 1
fi

values_file_from_helm="$(awk '{for (i=1;i<=NF;i++) if ($i=="--values") print $(i+1)}' "${MOCK_HELM_LOG}" | tail -n1)"
if [[ -z "${values_file_from_helm}" ]]; then
  echo "Expected Helm invocation to include a generated values file"
  exit 1
fi
if [[ -f "${values_file_from_helm}" ]]; then
  echo "Expected generated secret values file to be removed after install.sh exits"
  exit 1
fi

if ! PATH="${TMP_DIR}:${PATH}" \
  HELM_DEBUG=false \
  PROVIDER=openstack \
  SECRET_MODE=existing \
  EXISTING_SECRET_NAME=openstudio-app-secrets \
  RELEASE_NAME=openstudio-server \
  NAMESPACE=openstudio-server \
  CHART_PATH="${CHART_DIR}" \
  MOCK_NAMESPACE_MISSING=true \
  MOCK_SECRET_STATE=present \
  MOCK_KUBECTL_LOG="${MOCK_KUBECTL_LOG}" \
  MOCK_HELM_LOG="${MOCK_HELM_LOG}" \
  "${ROOT_DIR}/scripts/install.sh" >/dev/null; then
  echo "Expected install.sh existing mode to create missing namespace and validate secret"
  exit 1
fi

if ! grep -Fq "create namespace openstudio-server" "${MOCK_KUBECTL_LOG}"; then
  echo "Expected install.sh existing mode to create namespace before validation"
  exit 1
fi

echo "Helm lint/render matrix completed."
