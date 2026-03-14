#!/bin/bash
set -euo pipefail

# ============================================================
# BlueBubbles Cloudflare Tunnel Setup (Interactive)
#
# Run this on each macOS user account that has a BB instance.
# It will:
#   1. Install cloudflared if needed
#   2. Login to Cloudflare (if needed)
#   3. Ask for Clerk ID and BB port
#   4. Create/reuse a tunnel for this Mac
#   5. Route DNS and generate config
#   6. Start the tunnel
# ============================================================

DOMAIN="viatophone.com"
CONFIG_DIR="$HOME/.cloudflared"
CONFIG_FILE="$CONFIG_DIR/config.yml"

echo ""
echo "========================================="
echo "  ViatoPhone Tunnel Setup"
echo "========================================="
echo ""

# Step 1: Install cloudflared
if ! command -v cloudflared &> /dev/null; then
  echo "[1/6] cloudflared not found. Installing..."
  if command -v brew &> /dev/null; then
    brew install cloudflared
  else
    echo "Homebrew not found. Install cloudflared manually:"
    echo "  https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    exit 1
  fi
  echo "  Installed."
else
  echo "[1/6] cloudflared already installed. ✓"
fi

# Step 2: Login
if [ -f "$CONFIG_DIR/cert.pem" ]; then
  echo "[2/6] Already logged in to Cloudflare. ✓"
else
  echo "[2/6] Logging in to Cloudflare..."
  echo "  A browser window will open. Select '$DOMAIN' and authorize."
  echo ""
  cloudflared tunnel login
  if [ ! -f "$CONFIG_DIR/cert.pem" ]; then
    echo "  ERROR: Login failed. Try again."
    exit 1
  fi
  echo "  Logged in. ✓"
fi

# Step 3: Gather info
echo ""
echo "[3/6] Enter setup info:"
echo ""

read -p "  Mac name (e.g. mac-mini-1, joes-mac): " MAC_NAME
if [ -z "$MAC_NAME" ]; then
  echo "  ERROR: Mac name is required."
  exit 1
fi

read -p "  Clerk ID (e.g. user_3AMAoFUsg7KxtLyayVwqGRMMVoq): " CLERK_ID
if [ -z "$CLERK_ID" ]; then
  echo "  ERROR: Clerk ID is required."
  exit 1
fi

# Auto-detect BB port
BB_PORT=""
BB_PID=$(pgrep -f "BlueBubbles" 2>/dev/null | head -1 || true)
if [ -n "$BB_PID" ]; then
  # Try to find the listening port from lsof
  DETECTED_PORT=$(lsof -iTCP -sTCP:LISTEN -P -n -p "$BB_PID" 2>/dev/null | grep LISTEN | awk '{print $9}' | grep -o '[0-9]*$' | head -1 || true)
  if [ -n "$DETECTED_PORT" ]; then
    echo ""
    echo "  Detected BlueBubbles running on port $DETECTED_PORT"
    read -p "  Use port $DETECTED_PORT? (Y/n): " USE_DETECTED
    if [ -z "$USE_DETECTED" ] || [[ "$USE_DETECTED" =~ ^[Yy] ]]; then
      BB_PORT="$DETECTED_PORT"
    fi
  fi
fi

if [ -z "$BB_PORT" ]; then
  read -p "  BlueBubbles port: " BB_PORT
  if [ -z "$BB_PORT" ]; then
    echo "  ERROR: Port is required."
    exit 1
  fi
fi

SUBDOMAIN="${CLERK_ID}.${DOMAIN}"
echo ""
echo "  Summary:"
echo "    Mac:      $MAC_NAME"
echo "    Clerk ID: $CLERK_ID"
echo "    Port:     $BB_PORT"
echo "    URL:      https://$SUBDOMAIN"
echo ""
read -p "  Look good? (Y/n): " CONFIRM
if [[ "$CONFIRM" =~ ^[Nn] ]]; then
  echo "  Aborted."
  exit 0
fi

# Step 4: Create or reuse tunnel
echo ""
echo "[4/6] Setting up tunnel '$MAC_NAME'..."

# Try to find existing tunnel by name
TUNNEL_ID=""
while IFS= read -r line; do
  # cloudflared tunnel list outputs: ID NAME CREATED CONNECTIONS
  TUNNEL_NAME=$(echo "$line" | awk '{print $2}')
  if [ "$TUNNEL_NAME" = "$MAC_NAME" ]; then
    TUNNEL_ID=$(echo "$line" | awk '{print $1}')
    break
  fi
done < <(cloudflared tunnel list 2>/dev/null | tail -n +2)

# Handle names with spaces — try matching with full line
if [ -z "$TUNNEL_ID" ]; then
  while IFS= read -r line; do
    if echo "$line" | grep -q "$MAC_NAME"; then
      TUNNEL_ID=$(echo "$line" | awk '{print $1}')
      break
    fi
  done < <(cloudflared tunnel list 2>/dev/null | tail -n +2)
fi

if [ -n "$TUNNEL_ID" ]; then
  echo "  Tunnel '$MAC_NAME' already exists: $TUNNEL_ID ✓"
else
  CREATE_OUTPUT=$(cloudflared tunnel create "$MAC_NAME" 2>&1)
  echo "$CREATE_OUTPUT"
  # Extract UUID from output like "Created tunnel xxx with id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  TUNNEL_ID=$(echo "$CREATE_OUTPUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  if [ -z "$TUNNEL_ID" ]; then
    echo "  ERROR: Failed to create tunnel or extract tunnel ID."
    echo "  Output was: $CREATE_OUTPUT"
    exit 1
  fi
  echo "  Tunnel created: $TUNNEL_ID ✓"
fi

CREDS_FILE="$CONFIG_DIR/$TUNNEL_ID.json"
if [ ! -f "$CREDS_FILE" ]; then
  echo "  ERROR: Credentials file not found at $CREDS_FILE"
  exit 1
fi

# Step 5: Route DNS + write config
echo ""
echo "[5/6] Routing DNS and writing config..."

cloudflared tunnel route dns "$MAC_NAME" "$SUBDOMAIN" 2>/dev/null && echo "  DNS routed: $SUBDOMAIN ✓" || echo "  DNS route already exists ✓"

# Check if config already exists with other ingress rules (multi-user Mac)
if [ -f "$CONFIG_FILE" ]; then
  # Check if this subdomain is already in the config
  if grep -q "$SUBDOMAIN" "$CONFIG_FILE" 2>/dev/null; then
    echo "  Subdomain already in config. Updating port..."
  fi

  # Read existing ingress entries (excluding the catch-all and this subdomain)
  EXISTING_ENTRIES=$(python3 -c "
import yaml, sys
try:
    with open('$CONFIG_FILE') as f:
        cfg = yaml.safe_load(f)
    for rule in cfg.get('ingress', []):
        hostname = rule.get('hostname', '')
        service = rule.get('service', '')
        if hostname and hostname != '$SUBDOMAIN':
            print(f'{hostname}|{service}')
except:
    pass
" 2>/dev/null || true)
fi

# Write config with all entries
{
  echo "tunnel: $TUNNEL_ID"
  echo "credentials-file: $CREDS_FILE"
  echo ""
  echo "ingress:"

  # Re-add existing entries (other users on this Mac)
  if [ -n "${EXISTING_ENTRIES:-}" ]; then
    while IFS='|' read -r hostname service; do
      echo "  - hostname: $hostname"
      echo "    service: $service"
    done <<< "$EXISTING_ENTRIES"
  fi

  # Add this user
  echo "  - hostname: $SUBDOMAIN"
  echo "    service: http://localhost:$BB_PORT"
  echo "  - service: http_status:404"
} > "$CONFIG_FILE"

echo "  Config written ✓"
echo ""
echo "  Config contents:"
echo "  ---"
cat "$CONFIG_FILE" | sed 's/^/  /'
echo "  ---"

# Step 6: Print next steps
echo ""
echo "[6/6] Done! Next steps:"
echo ""
echo "  1. Start the tunnel:"
echo "     cloudflared tunnel run $MAC_NAME"
echo ""
echo "  2. Update the DB (run in Supabase SQL editor):"
echo "     UPDATE \"user_Data\""
echo "       SET \"phone_System\" = jsonb_set(\"phone_System\", '{blueBubblesUrl}', '\"https://$SUBDOMAIN\"')"
echo "       WHERE \"clerk_Id\" = '$CLERK_ID';"
echo ""
echo "  3. To run on boot (optional):"
echo "     sudo cloudflared service install"
echo ""
echo "  To add another user on this same Mac, run this script again."
echo ""
