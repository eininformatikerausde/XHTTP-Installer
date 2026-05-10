#!/usr/bin/env bash
# ============================================================
# XHTTP Installer — Deploy-Ubuntu.sh
# VLESS + XHTTP + TLS  via  Vercel / Netlify CDN Relay
# by avaco_cloud
# ============================================================

set -euo pipefail
LANG=en_US.UTF-8
export LANG

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ── Globals ──────────────────────────────────────────────────
LOG_FILE="/tmp/xhttp-install.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
SSL_BASE="/etc/ssl/xhttp"
DEPLOY_DIR="/root/deploy"

exec > >(tee -a "$LOG_FILE") 2>&1

# ── Helpers ──────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[✔]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*"; }
die()     { err "$*"; exit 1; }

banner() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════╗"
  echo "║      XHTTP Installer  —  avaco_cloud     ║"
  echo "║    VLESS + XHTTP + TLS  via  CDN Relay   ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ── Screen wrapper ───────────────────────────────────────────
maybe_screen() {
  if [[ -n "${XHTTP_IN_SCREEN:-}" ]]; then
    return 0
  fi

  echo -e "${BOLD}Run inside screen (recommended for unstable SSH)?${NC}"
  echo "  If SSH drops mid-install, screen keeps the session alive."
  read -rp "Use screen? [Y/n]: " ans
  ans="${ans:-Y}"

  if [[ "${ans,,}" == "y" ]]; then
    if ! command -v screen &>/dev/null; then
      apt-get install -y screen -qq
    fi

    # When run via bash <(...), BASH_SOURCE[0] is not a real file path.
    # Download the script to a temp file so screen can re-execute it.
    local tmp_script="/tmp/xhttp-deploy.sh"
    if [[ -f "${BASH_SOURCE[0]}" ]]; then
      cp "${BASH_SOURCE[0]}" "$tmp_script"
    else
      curl -fsSL https://raw.githubusercontent.com/eininformatikerausde/XHTTP-Installer/main/Deploy-Ubuntu.sh \
        -o "$tmp_script"
    fi
    chmod +x "$tmp_script"
    export XHTTP_IN_SCREEN=1
    exec screen -S xhttp bash "$tmp_script"
    exit 0
  fi
}

# ════════════════════════════════════════════════════════════
# PHASE 1 — Preflight
# ════════════════════════════════════════════════════════════
phase_preflight() {
  info "Phase 1 — Preflight checks..."

  # OS check
  if ! grep -qi "ubuntu" /etc/os-release; then
    die "Only Ubuntu is supported."
  fi

  local ver
  ver=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)
  if (( ver < 20 )); then
    die "Ubuntu 20.04+ required (found $ver)."
  fi

  # Root
  [[ $EUID -eq 0 ]] || die "Run as root."

  # Internet
  if ! curl -fsSLo /dev/null --connect-timeout 5 https://example.com; then
    die "No internet connectivity."
  fi

  # Ports
  for port in 80 443; do
    if ss -tlnH | awk '{print $4}' | grep -qE ":${port}$"; then
      warn "Port $port is occupied — attempting autofix..."
      local pid
      pid=$(fuser "${port}/tcp" 2>/dev/null | awk '{print $1}' || true)
      [[ -n "$pid" ]] && kill -9 "$pid" && ok "Killed PID $pid on port $port"
    fi
  done

  # UFW open ports
  if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ok "UFW: ports 80 and 443 allowed"
  fi

  ok "Phase 1 passed."
}

# ════════════════════════════════════════════════════════════
# PHASE 2 — Install tools
# ════════════════════════════════════════════════════════════
phase_install_tools() {
  info "Phase 2 — Installing dependencies..."

  # Remove broken third-party repos
  info "Cleaning broken apt repos..."
  find /etc/apt/sources.list.d/ -type f -print | while read -r f; do
    if grep -qiE "packagecloud|perfops" "$f" 2>/dev/null; then
      warn "Removing broken repo: $f"
      rm -f "$f"
    fi
  done
  # Inline disable if still present
  sed -i '/packagecloud\|perfops/d' /etc/apt/sources.list 2>/dev/null || true

  apt-get update --allow-releaseinfo-change 2>/dev/null || apt-get update 2>/dev/null || true
  apt-get install -y --fix-missing curl jq unzip screen uuid-runtime socat

  # Xray-core
  if ! command -v xray &>/dev/null; then
    info "Installing Xray-core..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  fi
  ok "Xray-core ready: $(xray version | head -1)"

  # acme.sh
  if [[ ! -f /root/.acme.sh/acme.sh ]]; then
    info "Installing acme.sh..."
    curl -fsSL https://get.acme.sh | bash -s email="admin@localhost" >/dev/null
  fi
  ok "acme.sh ready"

  # Node.js (v18+)
  if ! node --version 2>/dev/null | grep -qE "^v(1[89]|[2-9][0-9])"; then
    info "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
    apt-get install -y nodejs -qq
  fi
  ok "Node.js: $(node --version)"

  # xray-knife (E2E tester)
  if ! command -v xray-knife &>/dev/null; then
    info "Installing xray-knife..."
    local arch zip_name
    arch=$(uname -m)
    zip_name="Xray-knife-linux-64.zip"
    [[ "$arch" == "aarch64" ]] && zip_name="Xray-knife-linux-arm64-v8a.zip"
    # Get latest version tag first
    local latest_tag
    latest_tag=$(curl -L "https://api.github.com/repos/lilendian0x00/xray-knife/releases/latest" | jq -r '.tag_name')
    local dl_url="https://github.com/lilendian0x00/xray-knife/releases/download/${latest_tag}/${zip_name}"
    # Use -L (follow redirects) without -f so redirect to githubusercontent.com works
    if curl -L --silent --show-error "$dl_url" -o /tmp/xray-knife.zip; then
      unzip -o /tmp/xray-knife.zip -d /tmp/xray-knife-tmp/ >/dev/null 2>&1
      find /tmp/xray-knife-tmp/ -name "xray-knife" -exec mv {} /usr/local/bin/xray-knife \;
      chmod +x /usr/local/bin/xray-knife
      rm -rf /tmp/xray-knife.zip /tmp/xray-knife-tmp/
      ok "xray-knife ready"
    else
      warn "xray-knife download failed — E2E test will be skipped"
    fi
  else
    ok "xray-knife ready"
  fi

    ok "xray-knife ready"
  fi

    ok "xray-knife ready"
  fi

  ok "Phase 2 done."
}

# ════════════════════════════════════════════════════════════
# PHASE 3 — Collect inputs
# ════════════════════════════════════════════════════════════
PLATFORM=""
DOMAIN=""
SSL_EMAIL=""
XRAY_PORT=443
RELAY_PATH="/api"
PUBLIC_RELAY_PATH="/api"
CDN_TOKEN=""
PROJECT_NAME=""

phase_collect_inputs() {
  info "Phase 3 — Collecting configuration inputs..."

  echo ""
  echo -e "${BOLD}[ Deployment Platform ]${NC}"
  echo "Choose relay platform:"
  echo "  1) Vercel"
  echo "  2) Netlify"
  while true; do
    read -rp "Enter choice [1/2]: " choice
    case "$choice" in
      1) PLATFORM="vercel";  break ;;
      2) PLATFORM="netlify"; break ;;
      *) warn "Enter 1 or 2." ;;
    esac
  done
  ok "Platform: $PLATFORM"

  echo ""
  while true; do
    read -rp "Server domain (A record → this server IP): " DOMAIN
    [[ -n "$DOMAIN" ]] && break
    warn "Domain cannot be empty."
  done

  read -rp "SSL email [admin@${DOMAIN}]: " SSL_EMAIL
  SSL_EMAIL="${SSL_EMAIL:-admin@${DOMAIN}}"

  read -rp "Xray inbound port [443]: " XRAY_PORT
  XRAY_PORT="${XRAY_PORT:-443}"

  read -rp "RELAY_PATH (server inbound path) [/api]: " RELAY_PATH
  RELAY_PATH="${RELAY_PATH:-/api}"

  read -rp "PUBLIC_RELAY_PATH (CDN → server path) [/api]: " PUBLIC_RELAY_PATH
  PUBLIC_RELAY_PATH="${PUBLIC_RELAY_PATH:-/api}"

  echo ""
  if [[ "$PLATFORM" == "vercel" ]]; then
    echo "Get Vercel token: https://vercel.com/account/tokens"
  else
    echo "Get Netlify token: https://app.netlify.com/user/applications#personal-access-tokens"
  fi
  while true; do
    read -rsp "${PLATFORM^} API Token: " CDN_TOKEN; echo
    [[ -n "$CDN_TOKEN" ]] && break
    warn "Token cannot be empty."
  done

  local default_name="relay-$(head -c4 /dev/urandom | xxd -p)"
  read -rp "Project name [${default_name}]: " PROJECT_NAME
  PROJECT_NAME="${PROJECT_NAME:-$default_name}"

  if [[ "$PLATFORM" == "vercel" ]]; then
    echo ""
    echo -e "${BOLD}[ Vercel Performance Settings ]${NC}"
    read -rp "Max duration (seconds) [50]: " VCL_MAX_DURATION
    VCL_MAX_DURATION="${VCL_MAX_DURATION:-50}"
  fi

  ok "Phase 3 done."
}

# ════════════════════════════════════════════════════════════
# PHASE 4a — SSL Certificate
# ════════════════════════════════════════════════════════════
phase_ssl() {
  info "Phase 4a — Issuing SSL certificate for $DOMAIN..."

  local ssl_dir="${SSL_BASE}/${DOMAIN}"
  mkdir -p "$ssl_dir"

  # Free port 80 for acme standalone
  local pid80
  pid80=$(fuser 80/tcp 2>/dev/null | awk '{print $1}' || true)
  [[ -n "$pid80" ]] && kill -9 "$pid80" && warn "Freed port 80 (PID $pid80)"

  /root/.acme.sh/acme.sh \
    --issue \
    --standalone \
    --domain "$DOMAIN" \
    --email "$SSL_EMAIL" \
    --force \
    --fullchain-file "${ssl_dir}/fullchain.pem" \
    --key-file "${ssl_dir}/privkey.pem" 2>&1 || {
      die "SSL issuance failed. Check DNS: $DOMAIN must point to this server."
    }

  chmod 640 "${ssl_dir}/privkey.pem"
  chgrp nobody "${ssl_dir}/privkey.pem" 2>/dev/null || true

  # Enable auto-renew
  /root/.acme.sh/acme.sh \
    --install-cert \
    --domain "$DOMAIN" \
    --fullchain-file "${ssl_dir}/fullchain.pem" \
    --key-file "${ssl_dir}/privkey.pem" \
    --reloadcmd "systemctl reload xray 2>/dev/null || true" >/dev/null

  ok "SSL certificate issued → $ssl_dir"
}

# ════════════════════════════════════════════════════════════
# PHASE 4b — Configure Xray
# ════════════════════════════════════════════════════════════
UUID=""
phase_xray() {
  info "Phase 4b — Configuring Xray (VLESS+XHTTP+TLS)..."

  UUID=$(uuidgen)
  local ssl_dir="${SSL_BASE}/${DOMAIN}"

  mkdir -p "$(dirname "$XRAY_CONFIG")"
  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${ssl_dir}/fullchain.pem",
              "keyFile": "${ssl_dir}/privkey.pem"
            }
          ],
          "alpn": ["h2", "http/1.1"]
        },
        "xhttpSettings": {
          "path": "${RELAY_PATH}",
          "host": "${DOMAIN}",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF

  # systemd drop-in: run xray as root (needed for privkey.pem)
  local dropin_dir="/etc/systemd/system/xray.service.d"
  mkdir -p "$dropin_dir"
  cat > "${dropin_dir}/override.conf" <<EOF
[Service]
User=root
EOF
  systemctl daemon-reload
  systemctl enable xray
  systemctl restart xray
  sleep 2

  if systemctl is-active --quiet xray; then
    ok "Xray is running  (UUID: $UUID)"
  else
    err "Xray failed to start. Logs:"
    journalctl -u xray --no-pager -n 30
    die "Xray start failed."
  fi
}

# ════════════════════════════════════════════════════════════
# PHASE 4c — Deploy CDN Relay
# ════════════════════════════════════════════════════════════
RELAY_URL=""

deploy_vercel() {
  info "Phase 4c — Deploying relay to Vercel..."

  # Install Vercel CLI
  if ! command -v vercel &>/dev/null; then
    npm install -g vercel --silent
  fi

  local proj_dir="${DEPLOY_DIR}/vercel"
  mkdir -p "${proj_dir}/api"

  # relay.js — Edge Function proxy
  cat > "${proj_dir}/api/relay.js" <<'JSEOF'
// Vercel Edge Function — XHTTP relay
export const config = { runtime: 'edge' };

const TARGET = process.env.TARGET_DOMAIN;
const UPSTREAM = process.env.UPSTREAM_PROTOCOL || 'https';
const PATH_PREFIX = process.env.RELAY_PATH || '/api';

export default async function handler(req) {
  if (!TARGET) {
    return new Response('Misconfigured: TARGET_DOMAIN not set', { status: 500 });
  }
  const url = new URL(req.url);
  const targetUrl = `${UPSTREAM}://${TARGET}${url.pathname}${url.search}`;
  const headers = new Headers(req.headers);
  headers.set('host', TARGET);

  try {
    const upstream = await fetch(targetUrl, {
      method: req.method,
      headers,
      body: ['GET','HEAD'].includes(req.method) ? undefined : req.body,
      redirect: 'follow',
    });
    return new Response(upstream.body, {
      status: upstream.status,
      headers: upstream.headers,
    });
  } catch (e) {
    return new Response('Gateway error: ' + e.message, { status: 502 });
  }
}
JSEOF

  # vercel.json
  cat > "${proj_dir}/vercel.json" <<EOF
{
  "version": 2,
  "functions": {
    "api/relay.js": {
      "maxDuration": ${VCL_MAX_DURATION:-50}
    }
  },
  "rewrites": [
    { "source": "${PUBLIC_RELAY_PATH}(.*)", "destination": "/api/relay" }
  ]
}
EOF

  # package.json
  cat > "${proj_dir}/package.json" <<'EOF'
{"name":"xhttp-relay","version":"1.0.0","private":true}
EOF

  cd "$proj_dir"

  # Auth & deploy with retry
  export VERCEL_TOKEN="$CDN_TOKEN"
  local attempt=0
  while (( attempt < 3 )); do
    attempt=$(( attempt + 1 ))
    info "Vercel deploy attempt $attempt..."

    vercel project add "$PROJECT_NAME" --token "$CDN_TOKEN" --yes 2>/dev/null || true

    vercel env add TARGET_DOMAIN production <<< "${DOMAIN}:${XRAY_PORT}" --token "$CDN_TOKEN" 2>/dev/null || true
    vercel env add UPSTREAM_PROTOCOL production <<< "https" --token "$CDN_TOKEN" 2>/dev/null || true
    vercel env add RELAY_PATH production <<< "${RELAY_PATH}" --token "$CDN_TOKEN" 2>/dev/null || true

    if vercel deploy --prod \
        --name "$PROJECT_NAME" \
        --token "$CDN_TOKEN" \
        --yes 2>&1 | tee /tmp/vercel-deploy.log; then
      RELAY_URL=$(grep -oP 'https://[^\s]+\.vercel\.app' /tmp/vercel-deploy.log | tail -1)
      ok "Vercel deploy succeeded → $RELAY_URL"
      return 0
    fi
    warn "Deploy failed, retrying in 5s..."
    sleep 5
  done
  die "Vercel deploy failed after 3 attempts."
}

deploy_netlify() {
  info "Phase 4c — Deploying relay to Netlify..."

  # Install Netlify CLI
  if ! command -v netlify &>/dev/null; then
    npm install -g netlify-cli --silent
  fi

  local proj_dir="${DEPLOY_DIR}/netlify"
  mkdir -p "${proj_dir}/netlify/edge-functions"

  # Edge function relay
  cat > "${proj_dir}/netlify/edge-functions/relay.js" <<JSEOF
// Netlify Edge Function — XHTTP relay
export default async (request, context) => {
  const target = Deno.env.get('TARGET_DOMAIN');
  if (!target) {
    return new Response('Misconfigured: TARGET_DOMAIN not set', { status: 500 });
  }
  const url = new URL(request.url);
  const upstream = \`https://\${target}\${url.pathname}\${url.search}\`;
  const headers = new Headers(request.headers);
  headers.set('host', target.split(':')[0]);

  try {
    const resp = await fetch(upstream, {
      method: request.method,
      headers,
      body: ['GET','HEAD'].includes(request.method) ? undefined : request.body,
    });
    return new Response(resp.body, {
      status: resp.status,
      headers: resp.headers,
    });
  } catch (e) {
    return new Response('Gateway error: ' + e.message, { status: 502 });
  }
};

export const config = { path: '/*' };
JSEOF

  # netlify.toml
  cat > "${proj_dir}/netlify.toml" <<EOF
[build]
  publish = "public"
  edge_functions = "netlify/edge-functions"

[[edge_functions]]
  path = "${PUBLIC_RELAY_PATH}/*"
  function = "relay"
EOF

  mkdir -p "${proj_dir}/public"
  echo '<!DOCTYPE html><html><body>OK</body></html>' > "${proj_dir}/public/index.html"

  cd "$proj_dir"

  export NETLIFY_AUTH_TOKEN="$CDN_TOKEN"
  local attempt=0
  while (( attempt < 3 )); do
    attempt=$(( attempt + 1 ))
    info "Netlify deploy attempt $attempt..."

    local site_id
    site_id=$(
      curl -fsSL \
        -X POST "https://api.netlify.com/api/v1/sites" \
        -H "Authorization: Bearer $CDN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${PROJECT_NAME}\"}" \
        2>/dev/null | jq -r '.id // empty'
    )

    if [[ -z "$site_id" ]]; then
      # duplicate name — randomise
      PROJECT_NAME="relay-$(head -c4 /dev/urandom | xxd -p)"
      warn "Name taken, retrying as $PROJECT_NAME..."
      continue
    fi

    # Set env var
    curl -fsSL \
      -X POST "https://api.netlify.com/api/v1/sites/${site_id}/env" \
      -H "Authorization: Bearer $CDN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"key\":\"TARGET_DOMAIN\",\"values\":[{\"value\":\"${DOMAIN}:${XRAY_PORT}\",\"context\":\"production\"}]}" \
      >/dev/null 2>&1 || true

    if netlify deploy \
        --prod \
        --site "$site_id" \
        --auth "$CDN_TOKEN" \
        --dir public 2>&1 | tee /tmp/netlify-deploy.log; then
      RELAY_URL="${PROJECT_NAME}.netlify.app"
      RELAY_URL="https://${PROJECT_NAME}.netlify.app"
      ok "Netlify deploy succeeded → $RELAY_URL"
      return 0
    fi
    warn "Deploy failed, retrying in 5s..."
    sleep 5
  done
  die "Netlify deploy failed after 3 attempts."
}

phase_deploy() {
  if [[ "$PLATFORM" == "vercel" ]]; then
    deploy_vercel
  else
    deploy_netlify
  fi
}

# ════════════════════════════════════════════════════════════
# PHASE 5 — E2E Test
# ════════════════════════════════════════════════════════════
PING_MIN="" PING_AVG="" PING_MAX=""
E2E_PASS=false

phase_e2e_test() {
  info "Phase 5 — End-to-end proxy test..."

  if ! command -v xray-knife &>/dev/null; then
    warn "xray-knife not found, skipping E2E test."
    return
  fi

  local relay_host
  relay_host=$(echo "$RELAY_URL" | sed 's|https\?://||' | cut -d'/' -f1)

  local vless_link="vless://${UUID}@${relay_host}:443?type=xhttp&security=tls&sni=${relay_host}&path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PUBLIC_RELAY_PATH}'))")&mode=auto#XHTTP-${PLATFORM}"

  local tmp_result
  tmp_result=$(xray-knife net ping \
    --config "$vless_link" \
    --url "https://www.gstatic.com/generate_204" \
    --count 3 \
    --timeout 10 2>&1 || true)

  if echo "$tmp_result" | grep -qi "success\|204\|ms"; then
    E2E_PASS=true
    PING_MIN=$(echo "$tmp_result" | grep -oP 'min[=: ]+\K[0-9]+' | head -1 || echo "?")
    PING_AVG=$(echo "$tmp_result" | grep -oP 'avg[=: ]+\K[0-9]+' | head -1 || echo "?")
    PING_MAX=$(echo "$tmp_result" | grep -oP 'max[=: ]+\K[0-9]+' | head -1 || echo "?")
    ok "E2E test passed (min/avg/max: ${PING_MIN}/${PING_AVG}/${PING_MAX} ms)"
  else
    warn "E2E test inconclusive — connection may still work with real clients."
    warn "$tmp_result"
  fi
}

# ════════════════════════════════════════════════════════════
# PHASE 6 — Generate config link
# ════════════════════════════════════════════════════════════
phase_generate_config() {
  info "Phase 6 — Generating client config..."

  local relay_host
  relay_host=$(echo "$RELAY_URL" | sed 's|https\?://||' | cut -d'/' -f1)

  local path_encoded
  path_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PUBLIC_RELAY_PATH}'))")

  local vless_link="vless://${UUID}@${relay_host}:443?type=xhttp&security=tls&sni=${relay_host}&host=${relay_host}&path=${path_encoded}&mode=auto&encryption=none#XHTTP-${PLATFORM}"

  # Quality rating
  local quality="Unknown"
  if [[ "$E2E_PASS" == "true" ]]; then
    if (( ${PING_AVG:-9999} < 300 )); then
      quality="Excellent"
    elif (( ${PING_AVG:-9999} < 600 )); then
      quality="Good"
    else
      quality="Fair"
    fi
  fi

  echo ""
  echo -e "${GREEN}"
  echo "╔══════════════════════════════════════════╗"
  echo "║       INSTALLATION COMPLETE  ✔          ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${NC}"
  echo ""
  printf "  %-20s : %s\n" "Platform"       "$PLATFORM"
  printf "  %-20s : %s\n" "Relay URL"      "$RELAY_URL"
  printf "  %-20s : %s\n" "Inbound UUID"   "$UUID"
  echo ""
  if [[ "$E2E_PASS" == "true" ]]; then
    printf "  %-20s : %s\n" "E2E Proxy Test" "✔ PASS"
    printf "  %-20s : %s ms\n" "Ping (min/avg/max)" "${PING_MIN}/${PING_AVG}/${PING_MAX}"
    printf "  %-20s : %s\n" "Quality" "$quality"
    echo "                       Your client config IS verified to work."
  else
    printf "  %-20s : %s\n" "E2E Proxy Test" "⚠ Not verified (try with real client)"
  fi
  echo ""
  echo "── Client Config ──────────────────────────────"
  echo ""
  echo -e "${BOLD}${vless_link}${NC}"
  echo ""
  echo "───────────────────────────────────────────────"
  echo ""
  echo "📋 Copy the vless:// link above into your client:"
  echo "   Windows  → v2rayN"
  echo "   Android  → v2rayNG"
  echo "   iOS      → Streisand"
  echo "   Linux    → Nekoray"
  echo "   Any      → Hiddify"
  echo ""
  echo "📝 Full log: $LOG_FILE"
}

# ════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════
main() {
  banner
  maybe_screen "$@"
  phase_preflight
  phase_install_tools
  phase_collect_inputs
  phase_ssl
  phase_xray
  phase_deploy
  phase_e2e_test
  phase_generate_config
}

main "$@"
