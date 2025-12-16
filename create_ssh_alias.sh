#!/bin/bash
# ============================================================
# CREATE SSH ALIAS FOR OPENSTACK VMS 
# ============================================================


SSH_KEY="$HOME/mykey.pem"
SSH_USER="ubuntu"
NET_NAME="net_transport_vxlan" 

echo "=================================================="
echo "   SSH Alias Generator"
echo "=================================================="

# 1. Capture VM List into an Array for safe handling
# We use a temp file to avoid pipe issues and re-reading
mapfile -t VM_LIST < <(openstack server list --status ACTIVE -f value -c Name -c Networks)

if [ ${#VM_LIST[@]} -eq 0 ]; then
    echo "No active VMs found."
    exit 1
fi

# Display VMs with simple numbering
echo "Active VMs:"
i=1
for line in "${VM_LIST[@]}"; do
    # Extract just the name (first column) for display
    NAME=$(echo "$line" | awk '{print $1}')
    echo "$i) $NAME"
    ((i++))
done

echo ""
read -p "Enter number of VM to alias (e.g., 1): " VM_NUM

# 2. Validate Input (Must be a number)
if ! [[ "$VM_NUM" =~ ^[0-9]+$ ]]; then
    echo "Error: Please enter a valid number (e.g., '1'), not the VM name."
    exit 1
fi

# Adjust for 0-indexed array
INDEX=$((VM_NUM-1))

# Verify index is valid
if [ -z "${VM_LIST[$INDEX]}" ]; then
    echo "Error: Invalid selection number."
    exit 1
fi

# 3. Extract Name and IP
RAW_LINE="${VM_LIST[$INDEX]}"
VM_NAME=$(echo "$RAW_LINE" | awk '{print $1}')

# Robust IP Extraction: looks for the first valid IPv4 address in the line
VM_IP=$(echo "$RAW_LINE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)

if [[ -z "$VM_IP" ]]; then
    echo "Error: Could not find an IP address for $VM_NAME."
    echo "Raw output was: $RAW_LINE"
    exit 1
fi

echo " -> Selected: $VM_NAME ($VM_IP)"

# 4. Find Network ID for Namespace
NET_ID=$(openstack network show $NET_NAME -f value -c id)
DHCP_NS="qdhcp-$NET_ID"

if [[ -z "$NET_ID" ]]; then
    echo "Error: Could not find network ID for $NET_NAME."
    exit 1
fi

# 5. Create/Update Alias
ALIAS_NAME="ssh-${VM_NAME}"

# Define the function command
CMD="function $ALIAS_NAME { sudo ip netns exec $DHCP_NS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY $SSH_USER@$VM_IP; }"

BASHRC="$HOME/.bashrc"

# Check if alias already exists and warn/inform
if grep -q "function $ALIAS_NAME" "$BASHRC"; then
    echo "Updating existing alias in .bashrc..."
else
    echo "Adding new alias to .bashrc..."
fi

# Append to .bashrc
echo "" >> "$BASHRC"
echo "# Alias for $VM_NAME ($VM_IP) added on $(date)" >> "$BASHRC"
echo "$CMD" >> "$BASHRC"
echo "export -f $ALIAS_NAME" >> "$BASHRC"

# 6. Instructions
echo "=================================================="
echo "   Success!"
echo "=================================================="
echo "To use '$ALIAS_NAME', reload your shell:"
echo "  source ~/.bashrc"
echo "  $ALIAS_NAME"
echo ""

