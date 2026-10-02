#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
komuta-deploy — start a Komuta deploy from CI and optionally wait for the result.

Usage:
  komuta-deploy --service <id> [--mode build|image] [--ref <branch|tag>] [--sha <commit>]
                [--image <repo@sha256:...>] [--client-request-id <id>] [--wait] [--timeout <seconds>]
                [--api-url <url>]

The deploy token is read from KOMUTA_DEPLOY_TOKEN. Without it, the CI's OIDC identity is used:
GitHub Actions (permissions: id-token: write) or GitLab CI (id_tokens: KOMUTA_ID_TOKEN with aud set to the API URL).

Exit codes: 0 succeeded (or superseded by a newer deploy), 1 failed or cancelled,
2 timed out while waiting, 3 invalid usage, 4 request rejected by Komuta.
USAGE
}

service="" mode="build" ref="" sha="" image="" client_request_id="" wait="false" timeout="1800"
api_url="${KOMUTA_API_URL:-https://api.komuta.io}"

while [ $# -gt 0 ]; do
  case "$1" in
    --service) service="${2:-}"; shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --ref) ref="${2:-}"; shift 2 ;;
    --sha) sha="${2:-}"; shift 2 ;;
    --image) image="${2:-}"; shift 2 ;;
    --client-request-id) client_request_id="${2:-}"; shift 2 ;;
    --wait) wait="true"; shift ;;
    --no-wait) wait="false"; shift ;;
    --timeout) timeout="${2:-}"; shift 2 ;;
    --api-url) api_url="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 3 ;;
  esac
done

token="${KOMUTA_DEPLOY_TOKEN:-}"
oidc="false"
if [ -z "$token" ]; then
  if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    oidc="github"
  elif [ -n "${KOMUTA_ID_TOKEN:-}" ]; then
    oidc="gitlab"
  else
    echo "Set KOMUTA_DEPLOY_TOKEN, or run in GitHub Actions with permissions: id-token: write, or in GitLab CI with an id_tokens entry named KOMUTA_ID_TOKEN." >&2
    exit 3
  fi
fi
[ -n "$service" ] || { echo "--service is required." >&2; exit 3; }
case "$mode" in build|image) ;; *) echo "--mode must be build or image." >&2; exit 3 ;; esac
if [ "$mode" = "image" ] && ! printf '%s' "$image" | grep -Eq '@sha256:[0-9a-f]{64}$'; then
  echo "--image must be pinned by digest (repo@sha256:...) in image mode." >&2; exit 3
fi
case "$timeout" in ''|*[!0-9]*) echo "--timeout must be a number of seconds." >&2; exit 3 ;; esac
command -v curl >/dev/null || { echo "curl is required." >&2; exit 3; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 3; }

api_url="${api_url%/}"
audience="${KOMUTA_OIDC_AUDIENCE:-$api_url}"

refresh_token() {
  case "$oidc" in
    github)
      token=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
        "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$audience" | jq -r '.value // empty')
      [ -n "$token" ] || { echo "Could not obtain a GitHub OIDC token (is permissions: id-token: write set?)." >&2; exit 3; } ;;
    gitlab) token="$KOMUTA_ID_TOKEN" ;;
  esac
}
body=$(jq -nc \
  --arg mode "$mode" --arg ref "$ref" --arg sha "$sha" --arg image "$image" --arg crid "$client_request_id" \
  --arg provider "${KOMUTA_CI_PROVIDER:-}" --arg runUrl "${KOMUTA_CI_RUN_URL:-}" --arg actor "${KOMUTA_CI_ACTOR:-}" \
  '{mode: $mode}
   + (if $ref != "" and $mode == "build" then {ref: $ref} else {} end)
   + (if $sha != "" then {commitSha: $sha} else {} end)
   + (if $image != "" then {image: $image} else {} end)
   + (if $crid != "" then {clientRequestId: $crid} else {} end)
   + (({ciProvider: $provider, runUrl: $runUrl, actor: $actor} | with_entries(select(.value != ""))) as $m
      | if ($m | length) > 0 then {metadata: $m} else {} end)')

request() {
  local method="$1" url="$2" data="${3:-}" out status attempt=0
  out=$(mktemp)
  while true; do
    attempt=$((attempt + 1))
    refresh_token
    if [ -n "$data" ]; then
      status=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "$url" \
        -H "Authorization: Bearer $token" -H "X-Komuta-Service-Id: $service" -H "Content-Type: application/json" --data "$data") || status=000
    else
      status=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "$url" -H "Authorization: Bearer $token" -H "X-Komuta-Service-Id: $service") || status=000
    fi
    if { [ "$status" = "429" ] || [ "$status" = "503" ] || [ "$status" = "000" ]; } && [ "$attempt" -lt 30 ]; then
      sleep 10
      continue
    fi
    break
  done
  RESPONSE_STATUS="$status"
  RESPONSE_BODY=$(cat "$out")
  rm -f "$out"
}

request POST "$api_url/api/v1/deploy-hooks/services/$service/deployments" "$body"
if [ "$RESPONSE_STATUS" != "202" ] && [ "$RESPONSE_STATUS" != "200" ]; then
  message=$(printf '%s' "$RESPONSE_BODY" | jq -r '.error.message // .message // empty' 2>/dev/null || true)
  echo "Komuta rejected the deploy (HTTP $RESPONSE_STATUS): ${message:-$RESPONSE_BODY}" >&2
  exit 4
fi

deployment_id=$(printf '%s' "$RESPONSE_BODY" | jq -r '.deploymentId')
status=$(printf '%s' "$RESPONSE_BODY" | jq -r '.status')
status_url=$(printf '%s' "$RESPONSE_BODY" | jq -r '.statusUrl')
console_url=$(printf '%s' "$RESPONSE_BODY" | jq -r '.consoleUrl // empty')

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "deployment-id=$deployment_id"; echo "status=$status"; echo "console-url=$console_url"; } >> "$GITHUB_OUTPUT"
  fi
}

echo "Komuta deploy $deployment_id accepted: $status"
[ -n "$console_url" ] && echo "Console: $console_url"

if [ "$wait" != "true" ]; then
  emit
  exit 0
fi

deadline=$(( $(date +%s) + timeout ))
last=""
while true; do
  case "$status" in
    succeeded) emit; echo "Deploy succeeded."; exit 0 ;;
    superseded) emit; echo "Deploy was superseded by a newer deploy of the same service."; exit 0 ;;
    failed)
      reason=$(printf '%s' "$RESPONSE_BODY" | jq -r '.failureReason // empty')
      emit; echo "Deploy failed${reason:+: $reason}." >&2; exit 1 ;;
    cancelled) emit; echo "Deploy was cancelled." >&2; exit 1 ;;
  esac
  if [ "$(date +%s)" -ge "$deadline" ]; then
    emit; echo "Timed out after ${timeout}s waiting for deploy $deployment_id (last status: $status)." >&2; exit 2
  fi
  sleep 10
  request GET "$status_url"
  if [ "$RESPONSE_STATUS" != "200" ]; then
    echo "Status check returned HTTP $RESPONSE_STATUS; retrying." >&2
    continue
  fi
  status=$(printf '%s' "$RESPONSE_BODY" | jq -r '.status')
  if [ "$status" != "$last" ]; then
    position=$(printf '%s' "$RESPONSE_BODY" | jq -r '.queue.position // empty')
    eta=$(printf '%s' "$RESPONSE_BODY" | jq -r '.queue.estimatedStartSeconds // empty')
    echo "Status: $status${position:+ (queue position $position)}${eta:+, expected to start in ~${eta}s}"
    last="$status"
  fi
done
