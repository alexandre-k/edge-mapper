#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="$ROOT_DIR/.certs"
CERT_FILE="$CERT_DIR/localhost.pem"
KEY_FILE="$CERT_DIR/localhost-key.pem"

HOST="${HOST:-localhost}"
PORT="${PORT:-8443}"
MODE="web-server"
TRUST_CERT=0
FORCE_REGEN=0
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chrome)
      MODE="chrome"
      shift
      ;;
    --web-server)
      MODE="web-server"
      shift
      ;;
    --serve-build)
      MODE="serve-build"
      shift
      ;;
    --trust)
      TRUST_CERT=1
      shift
      ;;
    --regen-cert)
      FORCE_REGEN=1
      shift
      ;;
    --host)
      if [[ $# -lt 2 ]]; then
        echo "Error: --host requires an argument" >&2
        exit 1
      fi
      HOST="$2"
      shift 2
      ;;
    --port)
      if [[ $# -lt 2 ]]; then
        echo "Error: --port requires an argument" >&2
        exit 1
      fi
      PORT="$2"
      shift 2
      ;;
    --help|-h)
      cat <<EOF
Usage: ./scripts/run_web_https.sh [options] [-- extra flutter run args]

Runs Edge Mapper locally over HTTPS (default: https://localhost:8443) so
OpenStreetMap OAuth 2.0 popup sign-in (https://localhost:8443/osm_callback.html)
and Chrome Built-in AI (Gemini Nano 4) work seamlessly during development.

Options:
  --web-server   Run 'flutter run -d web-server' over HTTPS (default; open in your
                 existing Chrome profile where Gemini Nano 4 & OSM login live)
  --chrome       Run 'flutter run -d chrome' over HTTPS (launches a dev Chrome window)
  --serve-build  Serve the compiled build/web bundle over HTTPS via Python
  --trust        Trust the generated cert in Chrome's Linux NSS database (certutil)
  --regen-cert   Force regeneration of .certs/localhost.pem
  --host <host>  Bind hostname (default: localhost)
  --port <port>  Bind HTTPS port (default: 8443)
EOF
      exit 0
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

mkdir -p "$CERT_DIR"

if [[ $FORCE_REGEN -eq 1 || ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
  if command -v mkcert >/dev/null 2>&1; then
    echo "Generating locally trusted certificate with mkcert..."
    mkcert -cert-file "$CERT_FILE" -key-file "$KEY_FILE" "$HOST" localhost 127.0.0.1 ::1
  else
    GEN_ARGS=(--cert "$CERT_FILE" --key "$KEY_FILE" --host "$HOST")
    if [[ $FORCE_REGEN -eq 1 ]]; then
      GEN_ARGS+=(--force)
    fi
    python3 "$ROOT_DIR/scripts/gen_dev_cert.py" "${GEN_ARGS[@]}"
  fi
fi

if [[ $TRUST_CERT -eq 1 ]]; then
  if command -v certutil >/dev/null 2>&1 && [[ -d "$HOME/.pki/nssdb" ]]; then
    certutil -d "sql:$HOME/.pki/nssdb" -D -n "Edge Mapper Local Dev" >/dev/null 2>&1 || true
    # Trust as a peer/server leaf certificate ("P,,") — NEVER as a Root CA ("C,,").
    certutil -d "sql:$HOME/.pki/nssdb" -A -t "P,," -n "Edge Mapper Local Dev" -i "$CERT_FILE"
    echo "Trusted leaf cert '$CERT_FILE' in Chrome NSS database ($HOME/.pki/nssdb)."
    echo "Restart Chrome once if it was already open so it picks up the new cert."
  else
    echo "Could not auto-trust cert (certutil or ~/.pki/nssdb not found)."
    echo "In Chrome, you can either click Advanced -> Proceed, or enable chrome://flags/#allow-insecure-localhost."
  fi
fi

ENV_FILE="$ROOT_DIR/.env"
DART_DEFINE_ARGS=()
HAS_DEFINE_FILE=0
for arg in "${EXTRA_ARGS[@]}"; do
  if [[ "$arg" == --dart-define-from-file* ]]; then
    HAS_DEFINE_FILE=1
    break
  fi
done
if [[ $HAS_DEFINE_FILE -eq 0 && -f "$ENV_FILE" ]]; then
  DART_DEFINE_ARGS+=("--dart-define-from-file=$ENV_FILE")
fi

echo ""
echo "  HTTPS App URL:              https://${HOST}:${PORT}"
echo "  OSM OAuth 2.0 Redirect URI: https://${HOST}:${PORT}/osm_callback.html"
if [[ ${#DART_DEFINE_ARGS[@]} -gt 0 ]]; then
  echo "  Environment File:           $ENV_FILE"
fi
echo ""

if [[ "$MODE" == "serve-build" ]]; then
  exec python3 "$ROOT_DIR/scripts/gen_dev_cert.py" \
    --cert "$CERT_FILE" \
    --key "$KEY_FILE" \
    --host "$HOST" \
    --port "$PORT" \
    --serve-dir "$ROOT_DIR/build/web"
fi

FLUTTER_BIN="$ROOT_DIR/flutter/bin/flutter"
if [[ ! -x "$FLUTTER_BIN" ]]; then
  FLUTTER_BIN="$(command -v flutter)"
fi

cd "$ROOT_DIR"
exec "$FLUTTER_BIN" run \
  -d "$MODE" \
  --web-hostname="$HOST" \
  --web-port="$PORT" \
  --web-tls-cert-path="$CERT_FILE" \
  --web-tls-cert-key-path="$KEY_FILE" \
  "${DART_DEFINE_ARGS[@]}" \
  "${EXTRA_ARGS[@]}"
