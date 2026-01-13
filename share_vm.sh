#!/bin/bash

# --- CONFIGURATION ---
KEY_FILE="$HOME/tskey-api-tcd"
SENDGRID_KEY_FILE="$HOME/sendgrid-api-key"
TAILNET="-"
FROM_EMAIL="elcfardad@gmail.com"  # Change this
FROM_NAME="TCD Lab Admin"

if [ -f "$KEY_FILE" ]; then
    API_KEY=$(head -n 1 "$KEY_FILE" | tr -d '[:space:]')
else
    echo "Error: API key file not found"
    exit 1
fi

if [ -f "$SENDGRID_KEY_FILE" ]; then
    SENDGRID_KEY=$(head -n 1 "$SENDGRID_KEY_FILE" | tr -d '[:space:]')
else
    echo "Warning: SendGrid key not found. Emails will not be sent."
    SENDGRID_KEY=""
fi

command -v jq >/dev/null 2>&1 || { echo "Error: jq not installed"; exit 1; }
command -v at >/dev/null 2>&1 || { echo "Error: at not installed"; exit 1; }

echo "=== Tailscale VM Share Manager ==="

[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc" >/dev/null 2>&1

mapfile -t FUNCTION_NAMES < <(compgen -A function | grep "^ssh-")

if [ ${#FUNCTION_NAMES[@]} -eq 0 ]; then
    echo "No SSH functions found"
    exit 1
fi

echo "Available VMs:"
i=0
for func in "${FUNCTION_NAMES[@]}"; do
    echo "  [$i] ${func#ssh-}"
    ((i++))
done

read -p "Select VM number: " vm_index
SELECTED_FUNC="${FUNCTION_NAMES[$vm_index]}"
[ -z "$SELECTED_FUNC" ] && { echo "Invalid selection"; exit 1; }

echo ">> Targeting: $SELECTED_FUNC"

FUNC_BODY=$(type "$SELECTED_FUNC" | tail -n +2 | head -n -1)

NAMESPACE=$(echo "$FUNC_BODY" | grep -oP 'qdhcp-[a-f0-9-]+')
SSH_KEY=$(echo "$FUNC_BODY" | grep -oP '\-i\s+\K[^\s]+')
SSH_HOST=$(echo "$FUNC_BODY" | grep -oP 'ubuntu@[\d\.]+')

echo "   Namespace: $NAMESPACE"
echo "   Key: $SSH_KEY"
echo "   Target: $SSH_HOST"

exec_clean() {
    local cmd="$1"
    sudo ip netns exec "$NAMESPACE" ssh \
        -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -T \
        "$SSH_HOST" \
        "$cmd" 2>&1 | grep -v "^$"
}

echo ">> Checking Tailscale..."
TS_VER=$(exec_clean "tailscale version 2>/dev/null | head -1" | tr -d '\r\n' | awk '{print $1}')

if [ -z "$TS_VER" ]; then
    echo "   Installing Tailscale..."
    exec_clean "curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1" >/dev/null
    sleep 3
else
    echo "   Tailscale: $TS_VER"
fi

echo ">> Checking auth status..."
TS_IP=$(exec_clean "tailscale ip -4 2>/dev/null" | tr -d '\r\n ')

if [ -z "$TS_IP" ]; then
    echo "   Generating auth key..."
    
    KEY_RESP=$(curl -s -u "$API_KEY:" -X POST \
        "https://api.tailscale.com/api/v2/tailnet/$TAILNET/keys" \
        -d '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":false}}}}')
    
    AUTH_KEY=$(echo "$KEY_RESP" | jq -r '.key')
    
    if [ "$AUTH_KEY" == "null" ]; then
        echo "   Error generating key"
        exit 1
    fi
    
    echo "   Authenticating..."
    exec_clean "sudo tailscale up --authkey=$AUTH_KEY --ssh >/dev/null 2>&1" >/dev/null
    sleep 5
    
    TS_IP=$(exec_clean "tailscale ip -4 2>/dev/null" | tr -d '\r\n ')
fi

echo "   Tailscale IP: $TS_IP"

echo ">> Getting device info..."
HOSTNAME=$(exec_clean "hostname" | tr -d '\r\n ')
echo "   Hostname: $HOSTNAME"

DEVICES=$(curl -s -u "$API_KEY:" \
    "https://api.tailscale.com/api/v2/tailnet/$TAILNET/devices")

DEVICE_ID=$(echo "$DEVICES" | jq -r ".devices[] | select(.hostname==\"$HOSTNAME\") | .id")

if [ -z "$DEVICE_ID" ] || [ "$DEVICE_ID" == "null" ]; then
    echo "   Error: Device not found in API"
    exit 1
fi

echo "   Device ID: $DEVICE_ID"

read -p "Enter user email: " SHARE_EMAIL
read -p "Enter duration (e.g. 7 days, 2 weeks, 30 minutes): " DURATION

DURATION=$(echo "$DURATION" | tr -d "'\"")

echo ">> Creating invite..."
INVITE_RESP=$(curl -s -u "$API_KEY:" -X POST \
    "https://api.tailscale.com/api/v2/device/$DEVICE_ID/device-invites" \
    -H "Content-Type: application/json" \
    -d "[{\"invitee\":\"$SHARE_EMAIL\"}]")

INVITE_ID=$(echo "$INVITE_RESP" | jq -r '.[0].id' 2>/dev/null)
INVITE_URL=$(echo "$INVITE_RESP" | jq -r '.[0].inviteUrl' 2>/dev/null)

if [ "$INVITE_ID" == "null" ] || [ -z "$INVITE_ID" ]; then
    echo "   Error creating invite"
    echo "$INVITE_RESP" | jq .
    exit 1
fi

echo "   Invite created: $INVITE_ID"

# Send email via SendGrid
if [ -n "$SENDGRID_KEY" ] && [ -n "$INVITE_URL" ]; then
    echo ">> Sending invitation email..."
    
    EXPIRY_DATE=$(date -d "+$DURATION" '+%B %d, %Y at %H:%M %Z')
    
    EMAIL_JSON=$(cat <<EOF
{
  "personalizations": [{
    "to": [{"email": "$SHARE_EMAIL"}]
  }],
  "from": {
    "email": "$FROM_EMAIL",
    "name": "$FROM_NAME"
  },
  "subject": "Tailscale VM Access - $HOSTNAME",
  "content": [{
    "type": "text/plain",
    "value": "Hello,\n\nYou have been granted temporary Tailscale access to the following VM:\n\nVM Name: $HOSTNAME\nTailscale IP: $TS_IP\nAccess Duration: $DURATION\nExpires: $EXPIRY_DATE\n\nTo accept this invitation, click the link below:\n$INVITE_URL\n\nThis access will automatically be revoked after $DURATION.\n\n---\nThis is an automated message from TCD Lab Infrastructure."
  }]
}
EOF
)
    
    SEND_RESULT=$(curl -s -X POST https://api.sendgrid.com/v3/mail/send \
        -H "Authorization: Bearer $SENDGRID_KEY" \
        -H "Content-Type: application/json" \
        -d "$EMAIL_JSON")
    
    if [ -z "$SEND_RESULT" ]; then
        echo "   ✓ Email sent successfully to $SHARE_EMAIL"
    else
        echo "   ⚠ Email send failed: $SEND_RESULT"
        echo "   Manual invite link: $INVITE_URL"
    fi
else
    echo "   ⚠ SendGrid not configured. Manual invite link:"
    echo "   $INVITE_URL"
fi

# Schedule revocation
REVOKE_CMD="curl -s -u '$API_KEY:' -X DELETE 'https://api.tailscale.com/api/v2/device-invites/$INVITE_ID' && logger 'Revoked Tailscale access for $SHARE_EMAIL on $HOSTNAME'"
echo "$REVOKE_CMD" | at now + $DURATION 2>&1 | grep -v "warning:"

AT_STATUS=$?
if [ $AT_STATUS -eq 0 ]; then
    echo "   ✓ Auto-revocation scheduled for: $(date -d "+$DURATION" '+%Y-%m-%d %H:%M')"
fi

echo ""
echo "========================================="
echo "✓ SUCCESS"
echo "========================================="
echo "User: $SHARE_EMAIL"
echo "VM: $HOSTNAME ($TS_IP)"  
echo "Expires: $DURATION ($EXPIRY_DATE)"
echo "========================================="
