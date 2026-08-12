#!/usr/bin/env bash
# Sign a .app with a stable identity when available; otherwise ad-hoc (TCC resets each rebuild).
set -euo pipefail

APP="${1:?usage: sign-app.sh /path/to/App.app}"
IDENTITY="${CODESIGN_IDENTITY:-}"

pick_identity() {
  if [ -n "${IDENTITY}" ]; then
    printf '%s\n' "$IDENTITY"
    return
  fi
  local line name
  # Prefer valid identities only (-v).
  while IFS= read -r line; do
    name="$(printf '%s\n' "$line" | sed -n 's/.*"\(.*\)".*/\1/p')"
    [ -z "$name" ] && continue
    case "$name" in
      "EggplantRecorder Dev"|"Apple Development:"*|Developer\ ID\ Application:*)
        printf '%s\n' "$name"
        return
        ;;
    esac
  done < <(security find-identity -v -p codesigning 2>/dev/null || true)
  printf '\n'
}

IDENTITY="$(pick_identity)"
if [ -n "$IDENTITY" ]; then
  echo "codesign: stable identity → $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "codesign: WARNING ad-hoc — Screen Recording permission resets every rebuild"
  if security find-identity -p codesigning 2>/dev/null | grep -F 'Apple Development:' | grep -q CERT_EXPIRED; then
    echo "  Your Apple Development cert is expired. Renew in Xcode → Settings → Accounts → Manage Certificates → +"
  else
    echo "  Run: ./scripts/setup-dev-codesign.sh"
  fi
  codesign --force --deep --sign - "$APP"
fi

codesign -dv --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier|Authority)=' || true
