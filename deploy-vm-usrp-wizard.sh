#!/bin/bash
# ==============================================================================
# USRP SECURE DEPLOYMENT WIZARD (PRODUCTION - PERSISTENT CONFIGURATION)
#
# Description: 
# Automates deployment of USRP-connected Worker and Gateway VMs on OpenStack.
# Enforces strict 1-to-1 isolation using iptables FORWARD chain rules inside
# the Gateway VM. Ensures all configuration persists across reboots.
#
# Security Mechanism:
# - Gateway VM uses iptables to ONLY forward traffic from its paired Worker IP
# - Static routes are written to Netplan config for persistence
# - iptables rules are saved via iptables-persistent package
#
# Usage: ./deploy-vm-usrp-wizard.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuration & SSH Keys
# ------------------------------------------------------------------------------
if [ -f "$HOME/mykey.pem" ]; then
    VM_KEY="$HOME/mykey.pem"
elif [ -f "mykey.pem" ]; then
    VM_KEY="./mykey.pem"
else
    echo "Error: 'mykey.pem' not found in current directory or \$HOME."
    exit 1
fi

SSH_OPTS_VM="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $VM_KEY"
SSH_OPTS_HOST="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

IMAGE_NAME="ubuntu-24.04-uhd-ready"
FLAVOR="m1.small"
KEY_NAME="mykey"
NET_VXLAN="net_transport_vxlan"
SSH_USER_REMOTE="backup_2_mfrd"

# ------------------------------------------------------------------------------
# USRP Hardware Registry
# Format: "Name|Host|SSH_IP|Target_IP|Type|Bridge"
# ------------------------------------------------------------------------------
declare -A USRPS
USRPS[1]="X310 (mfrd)|mfrd|127.0.0.1|192.168.40.2|standard|br-usrp"
USRPS[2]="N210-1 (mfrd)|mfrd|127.0.0.1|10.0.53.2|standard|br-n210"
USRPS[3]="N210-2 (backup2mfrd)|backup2mfrd|10.10.10.45|192.168.10.2|manual|br-eno5"

# ------------------------------------------------------------------------------
# Host Selection
# ------------------------------------------------------------------------------
echo "=================================================="
echo "   Select Worker VM Placement"
echo "=================================================="
openstack hypervisor list -f value -c "Hypervisor Hostname" -c "Host IP" -c State | \
    awk '{print NR ") " $1 " (" $2 ") - " $3}'
echo ""
read -p "Select Host Number: " HOST_NUM

HOST_LIST=($(openstack hypervisor list -f value -c "Hypervisor Hostname"))
WORKER_HOST=${HOST_LIST[$((HOST_NUM-1))]}

if [[ -z "$WORKER_HOST" ]]; then 
    echo "Error: Invalid host selection."
    exit 1
fi

# ------------------------------------------------------------------------------
# USRP Device Selection
# ------------------------------------------------------------------------------
echo ""
echo "=================================================="
echo "   Select Target USRP Device"
echo "=================================================="
echo "  1) X310        (mfrd)"
echo "  2) N210-1      (mfrd)"
echo "  3) N210-2      (backup2mfrd)"
echo ""
read -p "Choice [1-3]: " USRP_CHOICE

IFS='|' read -r USRP_NAME USRP_HOST USRP_SSH_IP USRP_TARGET_IP USRP_TYPE USRP_BRIDGE \
    <<< "${USRPS[$USRP_CHOICE]}"

if [[ -z "$USRP_NAME" ]]; then 
    echo "Error: Invalid USRP selection."
    exit 1
fi

# ------------------------------------------------------------------------------
# Deployment Configuration
# ------------------------------------------------------------------------------
echo ""
read -p "Enter Worker VM Name (e.g., vm-on which node?-[x310,n210]-on which node?- user?): " WORKER_NAME
GATEWAY_NAME="gateway-${USRP_HOST}-to-${WORKER_NAME}"

echo ""
echo "Enter Base Security Group Name for the Worker VM."
echo "  Example: 'sg-worker-user1'"
read -p "Security Group [default: sg_allow_usrp_ssh]: " USER_SEC_GROUP
USER_SEC_GROUP=${USER_SEC_GROUP:-sg_allow_usrp_ssh}

# Auto-create User SG if missing
if ! openstack security group show "$USER_SEC_GROUP" >/dev/null 2>&1; then
    echo "Info: Creating security group '$USER_SEC_GROUP'..."
    openstack security group create "$USER_SEC_GROUP" \
        --description "Base SG for USRP Worker VMs" >/dev/null
    openstack security group rule create --proto tcp --dst-port 22 "$USER_SEC_GROUP" >/dev/null
    openstack security group rule create --proto icmp "$USER_SEC_GROUP" >/dev/null
    echo " -> Added SSH and ICMP rules."
else
    echo "Info: Using existing security group '$USER_SEC_GROUP'."
fi

# ------------------------------------------------------------------------------
# Cleanup Old Resources
# ------------------------------------------------------------------------------
if openstack server show "$WORKER_NAME" >/dev/null 2>&1; then 
    echo "Info: Deleting existing Worker VM..."
    openstack server delete "$WORKER_NAME"
fi
if openstack server show "$GATEWAY_NAME" >/dev/null 2>&1; then 
    echo "Info: Deleting existing Gateway VM..."
    openstack server delete "$GATEWAY_NAME"
fi

ISO_SG_NAME="sg-isolation-${WORKER_NAME}"
if openstack security group show "$ISO_SG_NAME" >/dev/null 2>&1; then
    echo "Info: Cleaning up old isolation security group..."
    openstack security group delete "$ISO_SG_NAME"
fi

sleep 3

# ------------------------------------------------------------------------------
# Deploy VMs with Isolation
# ------------------------------------------------------------------------------
echo ">>> Creating Isolation Security Group: $ISO_SG_NAME"
openstack security group create "$ISO_SG_NAME" \
    --description "Strict isolation for $GATEWAY_NAME" >/dev/null

echo ">>> Deploying Gateway VM on $USRP_HOST..."
openstack server create \
    --image ubuntu-24.04 \
    --flavor "$FLAVOR" \
    --network "$NET_VXLAN" \
    --key-name "$KEY_NAME" \
    --security-group "$ISO_SG_NAME" \
    --availability-zone "nova:$USRP_HOST" \
    "$GATEWAY_NAME" >/dev/null

echo ">>> Deploying Worker VM on $WORKER_HOST..."
openstack server create \
    --image "$IMAGE_NAME" \
    --flavor "$FLAVOR" \
    --network "$NET_VXLAN" \
    --key-name "$KEY_NAME" \
    --security-group "$USER_SEC_GROUP" \
    --availability-zone "nova:$WORKER_HOST" \
    "$WORKER_NAME" >/dev/null

echo ">>> Waiting for instances to become ACTIVE..."
while true; do
    S1=$(openstack server show "$GATEWAY_NAME" -f value -c status)
    S2=$(openstack server show "$WORKER_NAME" -f value -c status)
    if [[ "$S1" == "ACTIVE" && "$S2" == "ACTIVE" ]]; then break; fi
    sleep 3
done

GW_IP=$(openstack server show "$GATEWAY_NAME" -f value -c addresses | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
WK_IP=$(openstack server show "$WORKER_NAME" -f value -c addresses | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
GW_ID=$(openstack server show "$GATEWAY_NAME" -f value -c "OS-EXT-SRV-ATTR:instance_name")

echo " -> Gateway IP: $GW_IP"
echo " -> Worker IP:  $WK_IP"
echo " -> Instance ID: $GW_ID"

# ------------------------------------------------------------------------------
# Apply Isolation Rules (OpenStack Level)
# ------------------------------------------------------------------------------
echo ">>> Locking Gateway SG to Worker IP ($WK_IP)..."
openstack security group rule create --protocol tcp --remote-ip "$WK_IP/32" "$ISO_SG_NAME" >/dev/null
openstack security group rule create --protocol udp --remote-ip "$WK_IP/32" "$ISO_SG_NAME" >/dev/null
openstack security group rule create --protocol icmp --remote-ip "$WK_IP/32" "$ISO_SG_NAME" >/dev/null

# ------------------------------------------------------------------------------
# Hot-Plug OVS Bridge to Gateway
# ------------------------------------------------------------------------------
echo ">>> Attaching USRP Bridge ($USRP_BRIDGE) to Gateway..."

cat <<EOF > /tmp/interface.xml
<interface type='bridge'>
  <source bridge='$USRP_BRIDGE'/>
  <virtualport type='openvswitch'/>
  <model type='virtio'/>
</interface>
EOF

if [[ "$USRP_HOST" == "mfrd" ]]; then
    sudo docker cp /tmp/interface.xml nova_libvirt:/tmp/interface.xml
    sudo docker exec nova_libvirt virsh attach-device $GW_ID /tmp/interface.xml --live --config
else
    scp $SSH_OPTS_HOST /tmp/interface.xml ${SSH_USER_REMOTE}@${USRP_SSH_IP}:/tmp/interface.xml
    if [ $? -ne 0 ]; then echo "Error: SCP failed."; exit 1; fi
    
    ssh $SSH_OPTS_HOST ${SSH_USER_REMOTE}@${USRP_SSH_IP} \
        "sudo docker cp /tmp/interface.xml nova_libvirt:/tmp/interface.xml && \
         sudo docker exec nova_libvirt virsh attach-device $GW_ID /tmp/interface.xml --live --config"
    if [ $? -ne 0 ]; then echo "Error: Remote attach failed."; exit 1; fi
fi

# ------------------------------------------------------------------------------
# Configure Gateway VM (Persistent iptables + Routing)
# ------------------------------------------------------------------------------
NET_ID=$(openstack network show $NET_VXLAN -f value -c id)
DHCP_NS="qdhcp-$NET_ID"
USRP_SUBNET=$(echo $USRP_TARGET_IP | cut -d. -f1-3)
GW_USRP_IP="${USRP_SUBNET}.5"

wait_for_ssh() {
    local IP=$1
    echo "Waiting for SSH on $IP..."
    for i in {1..20}; do
        sudo ip netns exec $DHCP_NS ssh $SSH_OPTS_VM -o ConnectTimeout=2 ubuntu@$IP "echo ready" >/dev/null 2>&1
        if [ $? -eq 0 ]; then echo " -> SSH Ready."; return 0; fi
        sleep 3
    done
    echo "Error: SSH timeout on $IP"
    return 1
}

wait_for_ssh $GW_IP

echo ">>> Configuring Gateway VM (Persistent Firewall Rules)..."

# Commands to run on Gateway VM
CMD_GW="
# Configure USRP-facing interface
sudo ip addr add ${GW_USRP_IP}/24 dev ens7 2>/dev/null || sudo ip addr add ${GW_USRP_IP}/24 dev ens4 2>/dev/null
sudo ip link set ens7 up 2>/dev/null
sudo ip link set ens4 up 2>/dev/null

# Enable IP forwarding permanently
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf >/dev/null
sudo sysctl -w net.ipv4.ip_forward=1

# Install iptables-persistent to save rules across reboots
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq iptables-persistent

# Flush existing rules to start clean
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -X

# DEFAULT POLICY: DROP all forwarded traffic
sudo iptables -P FORWARD DROP

# ALLOW: Established and Related connections (return traffic)
sudo iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# WHITELIST: ONLY allow forwarding from Worker IP to USRP subnet
sudo iptables -A FORWARD -s $WK_IP -d ${USRP_SUBNET}.0/24 -j ACCEPT

# NAT: Masquerade outbound traffic to USRP
sudo iptables -t nat -A POSTROUTING -o ens7 -j MASQUERADE 2>/dev/null
sudo iptables -t nat -A POSTROUTING -o ens4 -j MASQUERADE 2>/dev/null

# Save rules permanently
sudo netfilter-persistent save
"

sudo ip netns exec $DHCP_NS ssh $SSH_OPTS_VM ubuntu@$GW_IP "$CMD_GW"

# ------------------------------------------------------------------------------
# Configure Worker VM (Persistent Static Route via Netplan)
# ------------------------------------------------------------------------------
echo ">>> Configuring Worker VM (Persistent Static Route)..."
wait_for_ssh $WK_IP

# Create Netplan config for persistent route
NETPLAN_CONFIG="network:
  version: 2
  ethernets:
    ens3:
      routes:
        - to: ${USRP_SUBNET}.0/24
          via: $GW_IP
"

CMD_WORKER="
# Write persistent route to Netplan config
echo '$NETPLAN_CONFIG' | sudo tee /etc/netplan/99-usrp-route.yaml >/dev/null
sudo chmod 600 /etc/netplan/99-usrp-route.yaml

# Apply Netplan configuration
sudo netplan apply
"

sudo ip netns exec $DHCP_NS ssh $SSH_OPTS_VM ubuntu@$WK_IP "$CMD_WORKER"

# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------
echo ">>> Testing Connectivity to USRP..."
sudo ip netns exec $DHCP_NS ssh $SSH_OPTS_VM ubuntu@$WK_IP "ping -c 3 $USRP_TARGET_IP"

if [ $? -eq 0 ]; then
    echo ""
    echo "===================================================="
    echo "  DEPLOYMENT SUCCESSFUL"
    echo "===================================================="
    echo "Worker VM:  $WORKER_NAME ($WK_IP)"
    echo "            [Security Group: $USER_SEC_GROUP]"
    echo "Gateway VM: $GATEWAY_NAME ($GW_IP)"
    echo "            [Isolation SG: $ISO_SG_NAME]"
    echo "            [Allows traffic ONLY from $WK_IP]"
    echo ""
    echo "USRP:       $USRP_TARGET_IP"
    echo ""
    echo "All configuration is PERSISTENT across reboots."
    echo "===================================================="
else
    echo "Error: Connectivity test failed."
    exit 1
fi
