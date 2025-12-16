#!/bin/bash
# ============================================================
# DEPLOY VM WITH PCI PASSTHROUGH (TEST)
# ============================================================

# CONFIGURATION
HOST_NAME="backup2mfrd"
HOST_IP="10.10.10.45"
PCI_ADDR="0000:b2:00.0"  # The isolated device
VM_NAME="vm-pci-gateway"
IMAGE="ubuntu-24.04-uhd-ready"
FLAVOR="m1.small"
NET="net_transport_vxlan"
SSH_USER_HOST="backup_2_mfrd"

# SSH KEYS
if [ -f "$HOME/mykey.pem" ]; then VM_KEY="$HOME/mykey.pem"; else VM_KEY="./mykey.pem"; fi
SSH_OPTS_VM="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $VM_KEY"
SSH_OPTS_HOST="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# 1. CLEANUP PREVIOUS
echo ">>> Cleaning up old VM..."
openstack server delete $VM_NAME >/dev/null 2>&1
sleep 5

# 2. CREATE VM
echo ">>> Deploying Gateway VM on $HOST_NAME..."
openstack server create --image ubuntu-24.04 --flavor "$FLAVOR" --network "$NET" --key-name "mykey" --availability-zone "nova:$HOST_NAME" --security-group "sg_allow_usrp_ssh" "$VM_NAME"

echo ">>> Waiting for ACTIVE state..."
while true; do
    STATUS=$(openstack server show "$VM_NAME" -f value -c status)
    if [[ "$STATUS" == "ACTIVE" ]]; then break; fi
    sleep 3
done

GW_IP=$(openstack server show "$VM_NAME" -f value -c addresses | grep -oE "$NET=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | cut -d= -f2)
GW_ID=$(openstack server show "$VM_NAME" -f value -c "OS-EXT-SRV-ATTR:instance_name")

echo " -> VM Created: $GW_IP ($GW_ID)"

# 3. PREPARE PCI XML
# 0000:b2:00.0 -> domain=0x0000, bus=0xb2, slot=0x00, function=0x0
cat <<EOF > /tmp/pci_device.xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0xb2' slot='0x00' function='0x0'/>
  </source>
</hostdev>
EOF

# 4. ATTACH DEVICE (REMOTE)
echo ">>> Attaching PCI Device via SSH..."
scp $SSH_OPTS_HOST /tmp/pci_device.xml ${SSH_USER_HOST}@${HOST_IP}:/tmp/pci_device.xml

# Note: Using -t to support sudo password if needed
ssh -t $SSH_OPTS_HOST ${SSH_USER_HOST}@${HOST_IP} "sudo docker cp /tmp/pci_device.xml nova_libvirt:/tmp/pci_device.xml && sudo docker exec nova_libvirt virsh attach-device $GW_ID /tmp/pci_device.xml --live --config"

if [ $? -eq 0 ]; then
    echo "SUCCESS: Device Attached."
else
    echo "ERROR: Attachment Failed."
    exit 1
fi

# 5. CONFIGURE VM (IP ADDRESS)
echo ">>> Waiting for VM SSH..."
NET_ID=$(openstack network show $NET -f value -c id)
DHCP_NS="qdhcp-$NET_ID"

for i in {1..30}; do
    sudo ip netns exec $DHCP_NS ssh $SSH_OPTS_VM ubuntu@$GW_IP "echo ready" >/dev/null 2>&1
    if [ $? -eq 0 ]; then break; fi
    sleep 2
done

echo ">>> Configuring USRP Interface..."
# We assume the new PCI card appears as the LAST interface.
# We will blindly try to configure all non-ens3 interfaces.
CMD="
sudo ip addr add 192.168.10.1/24 dev ens4 2>/dev/null
sudo ip link set ens4 up 2>/dev/null
sudo ip addr add 192.168.10.1/24 dev ens5 2>/dev/null
sudo ip link set ens5 up 2>/dev/null
sudo ip addr add 192.168.10.1/24 dev ens6 2>/dev/null
sudo ip link set ens6 up 2>/dev/null
ip a
"

sudo ip netns exec $DHCP_NS ssh $SSH_OPTS_VM ubuntu@$GW_IP "$CMD"

echo ">>> Done. Try logging in:"
echo "source ~/.bashrc"
echo "ssh-vm-pci-gateway"
