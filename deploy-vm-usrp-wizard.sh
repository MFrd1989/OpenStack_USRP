#!/bin/bash
# ============================================================
# USRP UNIVERSAL DEPLOYMENT WIZARD
# ============================================================


# VM SSH Key (for connecting to Ubuntu VMs)
if [ -f "$HOME/mykey.pem" ]; then
    VM_KEY="$HOME/mykey.pem"
elif [ -f "mykey.pem" ]; then
    VM_KEY="./mykey.pem"
else
    echo "Error: mykey.pem not found."
    exit 1
fi

# OPTS for VMs (uses mykey.pem)
SSH_OPTS_VM="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $VM_KEY"

# OPTS for HOSTS (uses your default ~/.ssh/id_rsa)
SSH_OPTS_HOST="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

IMAGE_NAME="ubuntu-24.04-uhd-ready"
FLAVOR="m1.small"
KEY_NAME="mykey"
SEC_GROUP="sg_allow_usrp_ssh"
NET_VXLAN="net_transport_vxlan"
SSH_USER_REMOTE="backup_2_mfrd"

# 1. USRP REGISTRY
declare -A USRPS
USRPS[1]="X310 (mfrd)|mfrd|127.0.0.1|192.168.40.2|standard|br-usrp"
USRPS[2]="N210-1 (mfrd)|mfrd|127.0.0.1|10.0.53.2|standard|br-n210"
USRPS[3]="N210-2 (backup2mfrd)|backup2mfrd|10.10.10.45|192.168.10.2|manual|br-eno5"

# 2. SELECT HOST
echo "=================================================="
echo "   Select Worker VM Location"
echo "=================================================="
openstack hypervisor list -f value -c "Hypervisor Hostname" -c "Host IP" -c State | awk '{print NR ") " $1 " (" $2 ") - " $3}'
echo ""
read -p "Select Host Number: " HOST_NUM
HOST_LIST=($(openstack hypervisor list -f value -c "Hypervisor Hostname"))
WORKER_HOST=${HOST_LIST[$((HOST_NUM-1))]}
if [[ -z "$WORKER_HOST" ]]; then echo "Invalid selection."; exit 1; fi

# 3. SELECT USRP
echo ""
echo "=================================================="
echo "   Select Target USRP Device"
echo "=================================================="
echo "  1) X310        (mfrd)"
echo "  2) N210-1      (mfrd)"
echo "  3) N210-2      (backup2mfrd)"
echo ""
read -p "Choice [1-3]: " USRP_CHOICE
IFS='|' read -r USRP_NAME USRP_HOST USRP_SSH_IP USRP_TARGET_IP USRP_TYPE USRP_BRIDGE <<< "${USRPS[$USRP_CHOICE]}"
if [[ -z "$USRP_NAME" ]]; then echo "Invalid selection."; exit 1; fi

# 4. DEPLOYMENT
echo ""
read -p "Enter Worker VM Name: " WORKER_NAME
GATEWAY_NAME="gateway-${USRP_HOST}-to-${WORKER_NAME}"

# Cleanup logic
if openstack server show "$WORKER_NAME" >/dev/null 2>&1; then openstack server delete "$WORKER_NAME"; fi
if openstack server show "$GATEWAY_NAME" >/dev/null 2>&1; then openstack server delete "$GATEWAY_NAME"; fi
sleep 3

echo ">>> Deploying Gateway on $USRP_HOST..."
openstack server create --image ubuntu-24.04 --flavor "$FLAVOR" --network "$NET_VXLAN" --key-name "$KEY_NAME" --security-group "$SEC_GROUP" --availability-zone "nova:$USRP_HOST" "$GATEWAY_NAME" >/dev/null

echo ">>> Deploying Worker on $WORKER_HOST..."
openstack server create --image "$IMAGE_NAME" --flavor "$FLAVOR" --network "$NET_VXLAN" --key-name "$KEY_NAME" --security-group "$SEC_GROUP" --availability-zone "nova:$WORKER_HOST" "$WORKER_NAME" >/dev/null

echo ">>> Waiting for ACTIVE state..."
while true; do
    S1=$(openstack server show "$GATEWAY_NAME" -f value -c status)
    S2=$(openstack server show "$WORKER_NAME" -f value -c status)
    if [[ "$S1" == "ACTIVE" && "$S2" == "ACTIVE" ]]; then break; fi
    sleep 3
done

# Fix IP Parsing
GW_IP=$(openstack server show "$GATEWAY_NAME" -f value -c addresses | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
WK_IP=$(openstack server show "$WORKER_NAME" -f value -c addresses | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
GW_ID=$(openstack server show "$GATEWAY_NAME" -f value -c "OS-EXT-SRV-ATTR:instance_name")

echo " -> Gateway IP: $GW_IP | Instance ID: $GW_ID"
echo " -> Worker IP:  $WK_IP"

# 5. CONFIGURATION (XML Attach)
echo ">>> Hot-Plugging Bridge ($USRP_BRIDGE)..."

cat <<EOF > /tmp/interface.xml
<interface type='bridge'>
  <source bridge='$USRP_BRIDGE'/>
  <virtualport type='openvswitch'/>
  <model type='virtio'/>
</interface>
EOF

if [[ "$USRP_HOST" == "mfrd" ]]; then
    # Local Attach
    sudo docker cp /tmp/interface.xml nova_libvirt:/tmp/interface.xml
    sudo docker exec nova_libvirt virsh attach-device $GW_ID /tmp/interface.xml --live --config
else
    # Remote Attach - USES SSH_OPTS_HOST (System Key)
    scp $SSH_OPTS_HOST /tmp/interface.xml ${SSH_USER_REMOTE}@${USRP_SSH_IP}:/tmp/interface.xml
    if [ $? -ne 0 ]; then echo "Error: SCP failed. Check SSH access to ${USRP_SSH_IP}"; exit 1; fi
    
    ssh $SSH_OPTS_HOST ${SSH_USER_REMOTE}@${USRP_SSH_IP} "sudo docker cp /tmp/interface.xml nova_libvirt:/tmp/interface.xml; sudo docker exec nova_libvirt virsh attach-device $GW_ID /tmp/interface.xml --live --config"
    if [ $? -ne 0 ]; then echo "Error: Remote attach failed."; exit 1; fi
fi

# Helper function to wait for SSH
wait_for_ssh() {
    local IP=$1
    echo "Waiting for SSH on $IP..."
    for i in {1..20}; do
        # USES SSH_OPTS_VM (mykey.pem)
        sudo ip netns exec $DHCP_NS ssh $SSH_OPTS_VM -o ConnectTimeout=2 ubuntu@$IP "echo ready" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo " -> SSH Ready."
            return 0
        fi
        sleep 3
    done
    echo " -> SSH Timed out."
    return 1
}

echo ">>> Configuring Gateway VM..."
NET_ID=$(openstack network show $NET_VXLAN -f value -c id)
DHCP_NS="qdhcp-$NET_ID"
USRP_SUBNET=$(echo $USRP_TARGET_IP | cut -d. -f1-3)
GW_USRP_IP="${USRP_SUBNET}.5"

wait_for_ssh $GW_IP

CMD_GW="sudo ip addr add ${GW_USRP_IP}/24 dev ens7 2>/dev/null; sudo ip link set ens7 up 2>/dev/null; \
        sudo ip addr add ${GW_USRP_IP}/24 dev ens4 2>/dev/null; sudo ip link set ens4 up 2>/dev/null; \
        sudo sysctl -w net.ipv4.ip_forward=1; \
        sudo iptables -t nat -A POSTROUTING -o ens7 -j MASQUERADE 2>/dev/null; \
        sudo iptables -t nat -A POSTROUTING -o ens4 -j MASQUERADE 2>/dev/null"

sudo ip netns exec $DHCP_NS ssh $SSH_OPTS_VM ubuntu@$GW_IP "$CMD_GW"

echo ">>> Configuring Worker VM..."
wait_for_ssh $WK_IP
sudo ip netns exec $DHCP_NS ssh $SSH_OPTS_VM ubuntu@$WK_IP "sudo ip route add ${USRP_SUBNET}.0/24 via $GW_IP"

echo ">>> Testing..."
sudo ip netns exec $DHCP_NS ssh $SSH_OPTS_VM ubuntu@$WK_IP "ping -c 3 $USRP_TARGET_IP"

