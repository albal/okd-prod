#!/usr/bin/env bash
set -euo pipefail

BUNDLE_NAME="${1:-okd-prod-init-bundle}"
NAMESPACE="stackrox"

echo "==> Getting Central route..."
CENTRAL_HOST=$(oc get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}')
echo "    Central: https://${CENTRAL_HOST}"

echo "==> Getting Central admin password..."
ADMIN_PASSWORD=$(oc get secret central-htpasswd -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

AUTH=$(echo -n "admin:${ADMIN_PASSWORD}" | base64 -w0)

echo "==> Checking for existing init-bundle '${BUNDLE_NAME}'..."
EXISTING=$(curl -sk -H "Authorization: Basic ${AUTH}" \
  "https://${CENTRAL_HOST}/v1/cluster-init/init-bundles" | \
  python3 -c "import json,sys; bundles=json.load(sys.stdin).get('items',[]); print(next((b['id'] for b in bundles if b['name']=='${BUNDLE_NAME}'), ''))")

if [[ -n "$EXISTING" ]]; then
  echo "    Bundle '${BUNDLE_NAME}' already exists (id: ${EXISTING})."
  echo "    To regenerate, delete it first via the ACS UI or API, then re-run this script."
  echo "    Checking if secrets are already applied..."
  if oc get secret sensor-tls -n "$NAMESPACE" &>/dev/null; then
    echo "    Secrets already present — nothing to do."
    exit 0
  fi
  echo "    ERROR: Bundle exists but secrets are missing. Delete the bundle and re-run."
  exit 1
fi

echo "==> Generating init-bundle '${BUNDLE_NAME}'..."
RESPONSE=$(curl -sk -X POST \
  -H "Authorization: Basic ${AUTH}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${BUNDLE_NAME}\"}" \
  "https://${CENTRAL_HOST}/v1/cluster-init/init-bundles")

# Check for errors
ERROR=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || true)
if [[ -n "$ERROR" ]]; then
  echo "ERROR: Central API returned: $ERROR"
  exit 1
fi

echo "==> Applying init-bundle secrets to namespace '${NAMESPACE}'..."
echo "$RESPONSE" | \
  python3 -c "import json,sys,base64; d=json.load(sys.stdin); print(base64.b64decode(d['kubectlBundle']).decode())" | \
  oc apply -n "$NAMESPACE" -f -

echo ""
echo "==> Done. Sensor, collector, and admission-controller should start shortly."
echo "    Watch with: oc get pods -n ${NAMESPACE} -w"
