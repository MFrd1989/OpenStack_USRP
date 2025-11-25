#!/bin/bash

# Check OpenStack credentials
if [[ -z "$OS_AUTH_URL" ]]; then
    echo "Error: OpenStack credentials not loaded. Source 'admin-openrc.sh' or 'kolla-venv' first."
    exit 1
fi

IMAGE_NAME="ubuntu-24.04-uhd-ready"
FLAVOR="m1.small"
KEY_NAME="mykey"         # Change if needed
ZONE="nova:backupmfrd"   # Availability Zone

echo "=================================================="
echo "   Universal USRP VM Deployment Wizard"
echo "=================================================="

# 1. Select USRP Type
echo "Which USRP environment do you want?"
echo "  1) X310 (Network: usrp_private | Target: 192.168.40.2)"
echo "  2) N210 (Network: n210_private | Target: 10.0.53.2)"
echo "  3) N210-2 (Network: n210_2_private | Target: 192.168.10.2)"
read -p "Select [1 or 2 or 3]: " USRP_CHOICE

if [[ "$USRP_CHOICE" == "1" ]]; then
    NET_NAME="usrp_private"
    DEFAULT_IP="192.168.40.2"
    PREFIX="x310"
elif [[ "$USRP_CHOICE" == "2" ]]; then
    NET_NAME="n210_private"
    DEFAULT_IP="10.0.53.2"
    PREFIX="n210"
elif [[ "$USRP_CHOICE" == "3" ]]; then
    NET_NAME="n210_2_private"
    DEFAULT_IP="192.168.10.2"
    PREFIX="n210-2"
else
    echo "Invalid choice. Exiting."
    exit 1
fi

# 2. Ask for VM Name
read -p "Enter new VM Name (e.g., vm-$PREFIX-worker-1): " VM_NAME
if [[ -z "$VM_NAME" ]]; then echo "Error: VM Name cannot be empty."; exit 1; fi

# 3. Confirm Target IP
read -p "Enter Target USRP IP (default: $DEFAULT_IP): " USRP_IP
USRP_IP=${USRP_IP:-$DEFAULT_IP}

echo "--------------------------------------------------"
echo "Deploying $VM_NAME..."
echo "Network:     $NET_NAME"
echo "Target USRP: $USRP_IP"
echo "Image:       $IMAGE_NAME"
echo "--------------------------------------------------"

# Create cloud-init config
cat <<EOF > /tmp/user_data_usrp.yml
#cloud-config
write_files:
  - path: /etc/usrp_ip
    content: |
      $USRP_IP
    permissions: '0644'
runcmd:
  - echo "USRP Target IP set to $USRP_IP" >> /var/log/usrp_init.log
EOF

# 4. Create the VM
openstack server create \
    --image "$IMAGE_NAME" \
    --flavor "$FLAVOR" \
    --network "$NET_NAME" \
    --key-name "$KEY_NAME" \
    --availability-zone "$ZONE" \
    --user-data /tmp/user_data_usrp.yml \
    "$VM_NAME"

# Cleanup
rm /tmp/user_data_usrp.yml

echo "=================================================="
echo "VM '$VM_NAME' is building."
echo "It will be isolated to the $PREFIX network."
echo "=================================================="
