#!/usr/bin/env bash

set -euo pipefail

REPO="${1:-RoachWares/RoachNet}"

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name" >&2
    exit 1
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

encode_cert_base64() {
  if [[ -n "${APPLE_DEVELOPER_ID_APP_CERT_BASE64:-}" ]]; then
    printf '%s' "$APPLE_DEVELOPER_ID_APP_CERT_BASE64"
    return 0
  fi

  require_env APPLE_DEVELOPER_ID_APP_CERT_PATH

  if [[ ! -f "$APPLE_DEVELOPER_ID_APP_CERT_PATH" ]]; then
    echo "Certificate file not found: $APPLE_DEVELOPER_ID_APP_CERT_PATH" >&2
    exit 1
  fi

  base64 < "$APPLE_DEVELOPER_ID_APP_CERT_PATH" | tr -d '\n'
}

set_secret() {
  local name="$1"
  local value="$2"
  printf '%s' "$value" | gh secret set "$name" --repo "$REPO"
}

main() {
  require_command gh
  require_command base64

  gh auth status >/dev/null

  require_env APPLE_DEVELOPER_ID_APP_CERT_PASSWORD
  require_env APPLE_DEVELOPER_ID_APP_IDENTITY
  require_env APPLE_NOTARY_APPLE_ID
  require_env APPLE_NOTARY_APP_PASSWORD
  require_env APPLE_NOTARY_TEAM_ID

  local cert_base64
  cert_base64="$(encode_cert_base64)"

  set_secret APPLE_DEVELOPER_ID_APP_CERT_BASE64 "$cert_base64"
  set_secret APPLE_DEVELOPER_ID_APP_CERT_PASSWORD "$APPLE_DEVELOPER_ID_APP_CERT_PASSWORD"
  set_secret APPLE_DEVELOPER_ID_APP_IDENTITY "$APPLE_DEVELOPER_ID_APP_IDENTITY"
  set_secret APPLE_NOTARY_APPLE_ID "$APPLE_NOTARY_APPLE_ID"
  set_secret APPLE_NOTARY_APP_PASSWORD "$APPLE_NOTARY_APP_PASSWORD"
  set_secret APPLE_NOTARY_TEAM_ID "$APPLE_NOTARY_TEAM_ID"

  echo "Configured Apple release secrets for $REPO"
}

main "$@"
