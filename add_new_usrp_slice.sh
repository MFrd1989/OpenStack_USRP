#!/bin/bash

# ==============================================================================
# Automate USRP Network Slicing
# 1. Creates OVS Bridge & Adds Interface
# 2. Updates Neutron Configs (mappings & flat networks)
# 3. Restarts Neutron Containers
# 4. Creates OpenStack Networks, Subnets, and Routers
# ==============================================================================

# Check OpenStack Auth
if [[ -z "$OS_AUTH_URL" ]]; then
    echo "Error: Source your 'admin-openrc.sh' or 'kolla-venv' first."
    exit 1
fi


echo "=================================================="
echo "   USRP Network Slice Generator"
echo "=================================================="

# --- 1. GATHER INPUTS ---
read -p "1. Enter a Short Name for this slice (e.g., n210_2): " SLICE_NAME
read -p "2. Enter the Physical Interface (e.g., eno4): " IFACE
read -p "3. Enter USRP Subnet CIDR (e.g., 192.168.10.0/24): " USRP_CIDR
read -p "4. Enter USRP Gateway IP (e.g., 192.168.10.1): " USRP_GW
read -p "5. Enter NEW VM Private Subnet CIDR (e.g., 10.0.60.0/24): " VM_CIDR

# Derived Variables
BRIDGE="br-${SLICE_NAME}"
PHYSNET="physnet_${SLICE_NAME}"
EXT_NET="extnet"  # Hardcoded based on the setup, change if needed
VM_GW="${VM_CIDR%.*}.1" # Assumes .1 gateway
DNS_IP="134.226.32.57"

echo "--------------------------------------------------"
echo "Configuration to Apply:"
echo "  Bridge:      $BRIDGE -> $IFACE"
echo "  Physnet:     $PHYSNET"
echo "  USRP Net:    $USRP_CIDR (Gateway: $USRP_GW)"
echo "  VM Net:      $VM_CIDR (Gateway: $VM_GW)"
echo "--------------------------------------------------"
read -p "Press Enter to proceed or Ctrl+C to cancel..."

# --- 2. HOST NETWORK CONFIGURATION ---
echo "[1/4] Configuring OVS Bridge..."
sudo ip link set "$IFACE" up
sudo ip addr flush dev "$IFACE"
# Only add bridge if it doesn't exist
if ! sudo ovs-vsctl br-exists "$BRIDGE"; then
    sudo ovs-vsctl add-br "$BRIDGE"
    sudo ovs-vsctl add-port "$BRIDGE" "$IFACE"
    echo "      Bridge $BRIDGE created."
else
    echo "      Bridge $BRIDGE already exists. Skipping."
fi

# --- 3. NEUTRON CONFIGURATION ---
echo "[2/4] Updating Neutron Configuration..."
OVS_CONF="/etc/kolla/neutron-openvswitch-agent/openvswitch_agent.ini"
ML2_CONF="/etc/kolla/neutron-server/ml2_conf.ini"

# Backup
sudo cp "$OVS_CONF" "${OVS_CONF}.bak"
sudo cp "$ML2_CONF" "${ML2_CONF}.bak"

# Check if mapping exists, if not, append it
if ! sudo grep -q "$PHYSNET" "$OVS_CONF"; then
    sudo sed -i "s/^bridge_mappings = .*/&,${PHYSNET}:${BRIDGE}/" "$OVS_CONF"
    echo "      Added bridge mapping to Agent config."
fi

if ! sudo grep -q "$PHYSNET" "$ML2_CONF"; then
    sudo sed -i "s/^flat_networks = .*/&,${PHYSNET}/" "$ML2_CONF"
    echo "      Added physical network to Server config."
fi

echo "      Restarting Neutron Containers (wait 15s)..."
sudo docker restart neutron_openvswitch_agent neutron_server > /dev/null
sleep 15

# --- 4. OPENSTACK RESOURCE CREATION ---
echo "[3/4] Creating OpenStack Resources..."

# USRP Public Network
openstack network create --share \
  --provider-physical-network "$PHYSNET" \
  --provider-network-type flat \
  "${SLICE_NAME}_public_net"

openstack subnet create --network "${SLICE_NAME}_public_net" \
  --subnet-range "$USRP_CIDR" \
  --gateway "$USRP_GW" \
  --allocation-pool start="${USRP_GW%.*}.10,end=${USRP_GW%.*}.200" \
  "${SLICE_NAME}_subnet"

# VM Private Network
openstack network create "${SLICE_NAME}_private"

openstack subnet create --network "${SLICE_NAME}_private" \
  --subnet-range "$VM_CIDR" \
  --gateway "$VM_GW" \
  --dns-nameserver "$DNS_IP" \
  "${SLICE_NAME}_private_subnet"

# Router
echo "[4/4] Configuring Router..."
ROUTER_NAME="${SLICE_NAME}_router"
openstack router create "$ROUTER_NAME"
openstack router set --external-gateway "$EXT_NET" "$ROUTER_NAME"
openstack router add subnet "$ROUTER_NAME" "${SLICE_NAME}_subnet"
openstack router add subnet "$ROUTER_NAME" "${SLICE_NAME}_private_subnet"

echo "=================================================="
echo "SUCCESS! Slice '$SLICE_NAME' is ready."
echo "VM Network: ${SLICE_NAME}_private"
echo "USRP Target IP: (Whatever device is on $IFACE)"
echo "=================================================="
