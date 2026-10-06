#!/bin/bash
# Discovers KServe models for Orca's OpenCode CLI.

umask 077

NS="${REDHAT_AI_NAMESPACE:-}"
OUT="${1:-${PROJECTS_ROOT:-/projects}/opencode.json}"

[ -z "$NS" ] && { echo "discover-models: REDHAT_AI_NAMESPACE not set, skipping"; exit 0; }

command -v oc &>/dev/null || { echo "discover-models: oc not found, skipping"; exit 0; }

if ! NAMES=$(oc get isvc -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); then
  echo "discover-models: cannot list InferenceServices in $NS; check cluster access, KServe, and permissions" >&2
  exit 0
fi
[ -z "$NAMES" ] && { echo "discover-models: no InferenceServices in $NS"; exit 0; }

TOKEN=$(cat /run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null) \
  || TOKEN=$(oc whoami -t 2>/dev/null) \
  || { echo "discover-models: no auth token"; exit 0; }

SERVICE_CA=/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
[ -f "$SERVICE_CA" ] && TLS=(--cacert "$SERVICE_CA") || TLS=(-k)

PROBES="["
SEP=""
for NAME in $NAMES; do
  URL="https://${NAME}-predictor.${NS}.svc.cluster.local:8443/v1"
  RESP=$(curl -sf "${TLS[@]}" -H "Authorization: Bearer $TOKEN" \
    --connect-timeout 5 "$URL/models" 2>/dev/null) || continue
  PROBES+="${SEP}{\"isvc\":\"$NAME\",\"url\":\"$URL\",\"resp\":$RESP}"
  SEP=","
done
PROBES+="]"

[ "$PROBES" = "[]" ] && { echo "discover-models: no reachable models"; exit 0; }

PROBES="$PROBES" node - "$OUT" <<'EOF'
const fs = require('fs');
const data = JSON.parse(process.env.PROBES);
const models = {};
let first = null;

for (const { isvc, url, resp } of data) {
  const m = resp.data && resp.data[0];
  if (!m) continue;

  const key = isvc.replace(/^isvc-/, '');
  if (!first) first = key;

  const label = key
    .split('-')
    .map(w =>
      /^(fp|bf)\d+$/i.test(w) ? `(${w.toUpperCase()})` :
      /^v\d/.test(w) ? w :
      w.charAt(0).toUpperCase() + w.slice(1)
    )
    .join(' ')
    .replace(/ \(/, ' (');

  models[key] = {
    id: m.id,
    name: label,
    tool_call: true,
    provider: { api: url },
    limit: { context: m.max_model_len || 65536, output: 8192 },
  };
}

if (!first) process.exit(0);

const config = {
  $schema: 'https://opencode.ai/config.json',
  model: `redhat/${first}`,
  small_model: `redhat/${first}`,
  provider: {
    redhat: {
      npm: '@ai-sdk/openai-compatible',
      name: 'Red Hat AI',
      options: {
        apiKey: '{file:/run/secrets/kubernetes.io/serviceaccount/token}',
      },
      models,
    },
  },
};

// Keep OpenCode's default tools and permissions.

fs.writeFileSync(process.argv[2], JSON.stringify(config, null, 2) + '\n');

console.error(`discover-models: wrote ${Object.keys(models).length} model(s) to ${process.argv[2]}`);

EOF
