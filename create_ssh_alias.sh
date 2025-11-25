#!/bin/bash

# Default SSH Key Path
SSH_KEY="~/mykey.pem"
SSH_USER="ubuntu"

if [[ -z "$OS_AUTH_URL" ]]; then
    echo "Error: Source your 'admin-openrc.sh' or 'kolla-venv' first."
    exit 1
fi

echo "=============================================="
echo "       OpenStack SSH Alias Generator"
echo "=============================================="

echo "Available VMs:"
openstack server list --status ACTIVE -f value -c Name

echo "----------------------------------------------"
read -p "Enter the VM Name to create alias for: " VM_NAME

if [[ -z "$VM_NAME" ]]; then echo "Error: Name cannot be empty."; exit 1; fi

# 1. Get VM IP
echo "Inspecting VM network..."
VM_IP=$(openstack server show "$VM_NAME" -f value -c addresses | grep -oP '\d+\.\d+\.\d+\.\d+' | head -n 1)

if [[ -z "$VM_IP" ]]; then
    echo "Error: Could not find an IP address for VM '$VM_NAME'."
    exit 1
fi
echo " > VM IP: $VM_IP"

# 2. Get Port ID first (This avoids the column error)
VM_PORT_ID=$(openstack port list --fixed-ip ip-address=$VM_IP -f value -c ID | head -n 1)

if [[ -z "$VM_PORT_ID" ]]; then
    echo "Error: Could not find Port ID for IP $VM_IP."
    exit 1
fi

# 3. Get Network ID from the Port Details
NET_ID=$(openstack port show "$VM_PORT_ID" -f value -c network_id)
echo " > Network ID: $NET_ID"

# 4. Find the Router ID
echo "Finding associated Router..."
# First, find the Port ID of the router interface on this network
ROUTER_PORT_ID=$(openstack port list --network "$NET_ID" --device-owner network:router_interface -f value -c ID | head -n 1)

# Fallback for HA routers
if [[ -z "$ROUTER_PORT_ID" ]]; then
    ROUTER_PORT_ID=$(openstack port list --network "$NET_ID" --device-owner network:ha_router_replicated_interface -f value -c ID | head -n 1)
fi

if [[ -z "$ROUTER_PORT_ID" ]]; then
    echo "Error: No Router Port found on network $NET_ID."
    exit 1
fi

# Get the Device ID (Router UUID) from the Router Port
ROUTER_ID=$(openstack port show "$ROUTER_PORT_ID" -f value -c device_id)
echo " > Router ID: $ROUTER_ID"

# 5. Create Alias
ALIAS_NAME="ssh-${VM_NAME}"
CMD="sudo ip netns exec qrouter-${ROUTER_ID} ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${SSH_USER}@${VM_IP}"

# 6. Save to .bashrc
BASHRC="$HOME/.bashrc"
sed -i "/alias $ALIAS_NAME=/d" "$BASHRC"
echo "alias $ALIAS_NAME='$CMD'" >> "$BASHRC"

echo "----------------------------------------------"
echo "Success! Alias added:"
echo "  $ALIAS_NAME"
echo ""
echo "To use it now, run:"
echo "  source ~/.bashrc"
echo "  $ALIAS_NAME"
echo "=============================================="
