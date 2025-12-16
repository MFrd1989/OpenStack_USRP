#!/bin/bash
# ============================================================
# USRP PCI PASSTHROUGH DEPLOYMENT WIZARD
# ============================================================


# --- CONFIGURATION ---
IMAGE_NAME="ubuntu-24.04-uhd-ready"
FLAVOR="m1.small"
KEY_NAME="mykey"
NET_VXLAN="net_transport_vxlan"
SSH_USER_HOST="backup_2_mfrd"   # User on Physical Compute Node
# ---------------------

# 1. SELECT HOST
echo "=================================================="
echo "   Select Host for PCI Passthrough"
echo "=================================================="
HOST_LIST=($(openstack hypervisor list -f value -c "Hypervisor Hostname"))
i=1
for host in "${HOST_LIST[@]}"; do echo "$i) $host"; ((i++)); done
read -p "Select Host Number: " HOST_NUM
WORKER_HOST=${HOST_LIST[$((HOST_NUM-1))]}
HOST_IP=$(openstack hypervisor show "$WORKER_HOST" -f value -c host_ip)
if [[ -z "$WORKER_HOST" ]]; then echo "Invalid selection."; exit 1; fi

# 2. SELECT PCI ADDRESS
echo ""
echo "=================================================="
echo "   Enter PCI Address (e.g., 0000:b2:00.0)"
echo "=================================================="
read -p "PCI Address: " PCI_ADDR

# 3. DEFINE VM
read -p "Enter Gateway VM Name: " VM_NAME

# 4. CREATE CLOUD-INIT CONFIG (Installs Firmware Automatically)
cat <<EOF > /tmp/user_data_firmware.yaml
#cloud-config
package_update: true
packages:
  - linux-firmware
runcmd:
  - modprobe -r bnx2x
  - modprobe bnx2x
EOF

# 5. DEPLOY VM
echo ">>> Deploying $VM_NAME on $WORKER_HOST..."
echo "    (Includes 500MB firmware install - boot will take ~2 mins)"

openstack server create \
    --image "$IMAGE_NAME" \
    --flavor "$FLAVOR" \
    --network "$NET_VXLAN" \
    --key-name "$KEY_NAME" \
    --availability-zone "nova:$WORKER_HOST" \
    --security-group "sg_allow_usrp_ssh" \
    --user-data /tmp/user_data_firmware.yaml \
    "$VM_NAME" >/dev/null

echo ">>> Waiting for VM to be ACTIVE..."
while true; do
    STATUS=$(openstack server show "$VM_NAME" -f value -c status)
    if [[ "$STATUS" == "ACTIVE" ]]; then break; fi
    sleep 3
done

GW_IP=$(openstack server show "$VM_NAME" -f value -c addresses | grep -oE "$NET_VXLAN=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | cut -d= -f2)
GW_ID=$(openstack server show "$VM_NAME" -f value -c "OS-EXT-SRV-ATTR:instance_name")
echo " -> IP: $GW_IP | Instance: $GW_ID"

# 6. ATTACH PCI DEVICE
# Convert 0000:b2:00.0 -> domain=0x0000 bus=0xb2 slot=0x00 function=0x0
DOMAIN=$(echo $PCI_ADDR | cut -d: -f1)
BUS=$(echo $PCI_ADDR | cut -d: -f2)
SLOT=$(echo $PCI_ADDR | cut -d: -f3 | cut -d. -f1)
FUNC=$(echo $PCI_ADDR | cut -d. -f2)

cat <<EOF > /tmp/pci_attach.xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x$DOMAIN' bus='0x$BUS' slot='0x$SLOT' function='0x$FUNC'/>
  </source>
</hostdev>
EOF

echo ">>> Attaching PCI Device ($PCI_ADDR)..."
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Copy XML to Host
scp $SSH_OPTS /tmp/pci_attach.xml ${SSH_USER_HOST}@${HOST_IP}:/tmp/pci_attach.xml

# Attach command (Interactive - might ask for sudo password)
ssh -t $SSH_OPTS ${SSH_USER_HOST}@${HOST_IP} "sudo docker cp /tmp/pci_attach.xml nova_libvirt:/tmp/pci_attach.xml && sudo docker exec nova_libvirt virsh attach-device $GW_ID /tmp/pci_attach.xml --live --config"

# 7. CONFIGURE NETWORKING (NAT)
echo ">>> Configuring VM Networking..."
echo "    (Waiting for cloud-init firmware install to finish...)"

# SSH Options for VM
if [ -f "$HOME/mykey.pem" ]; then KEY="$HOME/mykey.pem"; else KEY="./mykey.pem"; fi
SSH_VM="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $KEY"

# Wait for SSH
NET_ID=$(openstack network show $NET_VXLAN -f value -c id)
DHCP_NS="qdhcp-$NET_ID"

for i in {1..60}; do
    sudo ip netns exec $DHCP_NS ssh $SSH_VM ubuntu@$GW_IP "echo ready" >/dev/null 2>&1
    if [ $? -eq 0 ]; then break; fi
    echo -n "."
    sleep 5
done
echo ""

# Configure Command
# Note: We blindly try ens4-ens9 because PCI hotplug naming varies
CMD="
echo '>>> Waiting for driver reload...';
while ! ip link show | grep -q 'state UP'; do sudo ip link set ens4 up 2>/dev/null; sudo ip link set ens5 up 2>/dev/null; sudo ip link set ens6 up 2>/dev/null; sudo ip link set ens7 up 2>/dev/null; sudo ip link set ens8 up 2>/dev/null; sleep 2; done;
echo '>>> Configuring IP...';
sudo ip addr add 192.168.10.1/24 dev ens4 2>/dev/null;
sudo ip addr add 192.168.10.1/24 dev ens5 2>/dev/null;
sudo ip addr add 192.168.10.1/24 dev ens6 2>/dev/null;
sudo ip addr add 192.168.10.1/24 dev ens7 2>/dev/null;
sudo ip addr add 192.168.10.1/24 dev ens8 2>/dev/null;
sudo sysctl -w net.ipv4.ip_forward=1;
sudo iptables -t nat -A POSTROUTING -o ens+ -j MASQUERADE;
echo '>>> DONE. Gateway Ready.';
"

sudo ip netns exec $DHCP_NS ssh $SSH_VM ubuntu@$GW_IP "$CMD"

echo "=================================================="
echo "   DEPLOYMENT COMPLETE"
echo "=================================================="
echo "Your Gateway VM ($GW_IP) is ready."
echo "Use your alias script to login and test: 'ping 192.168.10.2'"
