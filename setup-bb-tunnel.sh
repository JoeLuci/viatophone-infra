#!/bin/bash
set -euo pipefail

# ============================================================
# BlueBubbles Cloudflare Tunnel Setup (Interactive)
#
# Run this on each macOS user account that has a BB instance.
# It handles everything: install, login, tunnel, DNS, config,
# service install, and starts the tunnel.
#
# Re-run to add another user on the same Mac — it preserves
# existing ingress rules.
# ============================================================

DOMAIN="viatophone.com"
CONFIG_DIR="$HOME/.cloudflared"
CONFIG_FILE="$CONFIG_DIR/config.yml"
SERVICE_CONFIG="/etc/cloudflared/config.yml"
SERVICE_CREDS_DIR="/etc/cloudflared"

echo ""
echo "========================================="
echo "  ViatoPhone Tunnel Setup"
echo "========================================="
echo ""

# Step 1: Install cloudflared
if ! command -v cloudflared &> /dev/null; then
  echo "[1/7] cloudflared not found. Installing..."
  if command -v brew &> /dev/null; then
    brew install cloudflared
  else
    echo "Homebrew not found. Installing Homebrew first..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew install cloudflared
  fi
  echo "  Installed."
else
  echo "[1/7] cloudflared already installed."
fi

# Step 2: Login
if [ -f "$CONFIG_DIR/cert.pem" ]; then
  echo "[2/7] Already logged in to Cloudflare."
else
  echo "[2/7] Logging in to Cloudflare..."
  echo "  A browser window will open. Select '$DOMAIN' and authorize."
  echo ""
  cloudflared tunnel login
  if [ ! -f "$CONFIG_DIR/cert.pem" ]; then
    echo "  ERROR: Login failed. Try again."
    exit 1
  fi
  echo "  Logged in."
fi

# Step 3: Gather info
echo ""
echo "[3/7] Enter setup info:"
echo ""

read -p "  Mac name (use dashes, no spaces, e.g. mm-az-03): " MAC_NAME
if [ -z "$MAC_NAME" ]; then
  echo "  ERROR: Mac name is required."
  exit 1
fi
# Replace spaces with dashes
MAC_NAME=$(echo "$MAC_NAME" | tr ' ' '-')

read -p "  Clerk ID (e.g. user_3AMAoFUsg7KxtLyayVwqGRMMVoq): " CLERK_ID
if [ -z "$CLERK_ID" ]; then
  echo "  ERROR: Clerk ID is required."
  exit 1
fi

# Ask for BB port (don't auto-detect — it picks up wrong ports)
read -p "  BlueBubbles port (check BB settings): " BB_PORT
if [ -z "$BB_PORT" ]; then
  echo "  ERROR: Port is required."
  exit 1
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
echo "[4/7] Setting up tunnel '$MAC_NAME'..."

TUNNEL_ID=""

# Check existing tunnels
if cloudflared tunnel list 2>/dev/null | grep -q "$MAC_NAME"; then
  TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | grep "$MAC_NAME" | awk '{print $1}')
fi

if [ -n "$TUNNEL_ID" ]; then
  echo "  Tunnel '$MAC_NAME' already exists: $TUNNEL_ID"
else
  CREATE_OUTPUT=$(cloudflared tunnel create "$MAC_NAME" 2>&1)
  echo "$CREATE_OUTPUT"
  TUNNEL_ID=$(echo "$CREATE_OUTPUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  if [ -z "$TUNNEL_ID" ]; then
    echo "  ERROR: Failed to create tunnel or extract tunnel ID."
    exit 1
  fi
  echo "  Tunnel created: $TUNNEL_ID"
fi

CREDS_FILE="$CONFIG_DIR/$TUNNEL_ID.json"
if [ ! -f "$CREDS_FILE" ]; then
  echo "  ERROR: Credentials file not found at $CREDS_FILE"
  exit 1
fi

# Step 5: Route DNS + write user config
echo ""
echo "[5/7] Routing DNS and writing config..."

cloudflared tunnel route dns "$MAC_NAME" "$SUBDOMAIN" 2>&1 | grep -v "^$" || true
echo "  DNS routed: $SUBDOMAIN"

# Collect existing ingress entries from current config (if any)
EXISTING_HOSTNAMES=()
EXISTING_SERVICES=()
if [ -f "$CONFIG_FILE" ]; then
  while IFS= read -r line; do
    if echo "$line" | grep -q "hostname:"; then
      h=$(echo "$line" | sed 's/.*hostname: *//')
      read -r sline
      s=$(echo "$sline" | sed 's/.*service: *//')
      if [ "$h" != "$SUBDOMAIN" ]; then
        EXISTING_HOSTNAMES+=("$h")
        EXISTING_SERVICES+=("$s")
      fi
    fi
  done < "$CONFIG_FILE"
fi

# Write config
printf "tunnel: %s\ncredentials-file: %s\n\ningress:\n" "$TUNNEL_ID" "$CREDS_FILE" > "$CONFIG_FILE"

for i in "${!EXISTING_HOSTNAMES[@]}"; do
  printf "  - hostname: %s\n    service: %s\n" "${EXISTING_HOSTNAMES[$i]}" "${EXISTING_SERVICES[$i]}" >> "$CONFIG_FILE"
done

printf "  - hostname: %s\n    service: http://localhost:%s\n  - service: http_status:404\n" "$SUBDOMAIN" "$BB_PORT" >> "$CONFIG_FILE"

echo "  User config written to $CONFIG_FILE"
echo ""
cat "$CONFIG_FILE"
echo ""

# Step 6: Install as service with correct paths
echo "[6/7] Installing as system service..."

sudo mkdir -p "$SERVICE_CREDS_DIR"
sudo cp "$CREDS_FILE" "$SERVICE_CREDS_DIR/"

# Write service config with /etc/cloudflared paths
printf "tunnel: %s\ncredentials-file: %s/%s.json\n\ningress:\n" "$TUNNEL_ID" "$SERVICE_CREDS_DIR" "$TUNNEL_ID" | sudo tee "$SERVICE_CONFIG" > /dev/null

for i in "${!EXISTING_HOSTNAMES[@]}"; do
  printf "  - hostname: %s\n    service: %s\n" "${EXISTING_HOSTNAMES[$i]}" "${EXISTING_SERVICES[$i]}" | sudo tee -a "$SERVICE_CONFIG" > /dev/null
done

printf "  - hostname: %s\n    service: http://localhost:%s\n  - service: http_status:404\n" "$SUBDOMAIN" "$BB_PORT" | sudo tee -a "$SERVICE_CONFIG" > /dev/null

echo "  Service config written to $SERVICE_CONFIG"
echo ""
sudo cat "$SERVICE_CONFIG"
echo ""

# Install and start service
if sudo launchctl list 2>/dev/null | grep -q "com.cloudflare.cloudflared"; then
  echo "  Service already installed. Restarting..."
  sudo launchctl stop com.cloudflare.cloudflared 2>/dev/null || true
  sleep 1
  sudo launchctl start com.cloudflare.cloudflared
else
  sudo cloudflared service install 2>/dev/null || true
fi

echo "  Service started."

# Step 7: Verify
echo ""
echo "[7/7] Verifying tunnel..."
sleep 3

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://$SUBDOMAIN" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "000" ] || [ "$HTTP_CODE" = "530" ]; then
  echo "  WARNING: Tunnel not responding yet (HTTP $HTTP_CODE)."
  echo "  It may take a minute. Check with:"
  echo "    curl -s https://$SUBDOMAIN"
  echo ""
  echo "  If it keeps failing, check service logs:"
  echo "    sudo log show --predicate 'process == \"cloudflared\"' --last 5m"
else
  echo "  Tunnel is live! (HTTP $HTTP_CODE)"
fi

echo ""
echo "========================================="
echo "  Setup complete!"
echo "========================================="
echo ""
echo "  Permanent URL: https://$SUBDOMAIN"
echo "  Tunnel runs on boot automatically."
echo ""
echo "  DB update SQL:"
echo "  UPDATE \"user_Data\""
echo "    SET \"phone_System\" = jsonb_set(\"phone_System\", '{blueBubblesUrl}', '\"https://$SUBDOMAIN\"')"
echo "    WHERE \"clerk_Id\" = '$CLERK_ID';"
echo ""
echo "  To add another user on this Mac, run this script again."
echo ""
