#!/bin/bash
# ============================================================
# SWITCH NODE MODE (OVS vs PCI-PASSTHROUGH)
# Target: backup2mfrd (Node 3)
# ============================================================
HOST_USER="backup_2_mfrd"
HOST_IP="10.10.10.45"
PCI_0="0000:b2:00.0"
PCI_1="0000:b2:00.1"
INTERFACE="eno5"
BRIDGE="br-eno5"

if [ -z "$1" ]; then echo "Usage: $0 [ovs|pci]"; exit 1; fi
MODE=$1

function remote_exec() {
    echo " -> Executing on $HOST_IP..."
    ssh -t -o StrictHostKeyChecking=no ${HOST_USER}@${HOST_IP} "$1"
}

if [ "$MODE" == "pci" ]; then
    echo ">>> SWITCHING TO PCI MODE..."
    CMD="
    sudo modprobe vfio-pci
    
    # Unbind from bnx2x (ignore errors)
    echo '$PCI_0' | sudo tee /sys/bus/pci/drivers/bnx2x/unbind 2>/dev/null || true
    echo '$PCI_1' | sudo tee /sys/bus/pci/drivers/bnx2x/unbind 2>/dev/null || true

    # Bind to VFIO
    echo 'vfio-pci' | sudo tee /sys/bus/pci/devices/$PCI_0/driver_override
    echo '$PCI_0' | sudo tee /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
    
    echo 'vfio-pci' | sudo tee /sys/bus/pci/devices/$PCI_1/driver_override
    echo '$PCI_1' | sudo tee /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true

    lspci -nnk -s $PCI_0 | grep 'Kernel driver'
    "
    remote_exec "$CMD"

elif [ "$MODE" == "ovs" ]; then
    echo ">>> SWITCHING TO OVS MODE..."
    CMD="
    # 1. Unbind from VFIO
    echo '$PCI_0' | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
    echo '$PCI_1' | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true

    # 2. Clear Override
    echo -n '' | sudo tee /sys/bus/pci/devices/$PCI_0/driver_override
    echo -n '' | sudo tee /sys/bus/pci/devices/$PCI_1/driver_override

    # 3. FORCE BIND to bnx2x (Try multiple paths)
    echo 'Binding to bnx2x...'
    sudo modprobe bnx2x
    
    # Method A: Driver Bind
    echo '$PCI_0' | sudo tee /sys/bus/pci/drivers/bnx2x/bind 2>/dev/null || true
    echo '$PCI_1' | sudo tee /sys/bus/pci/drivers/bnx2x/bind 2>/dev/null || true
    
    # Method B: Device Probe
    echo 1 | sudo tee /sys/bus/pci/devices/$PCI_0/remove 2>/dev/null
    echo 1 | sudo tee /sys/bus/pci/rescan

    # 4. Wait for Interface
    echo 'Waiting for interface...'
    for i in {1..10}; do
        if ip link show $INTERFACE >/dev/null 2>&1; then 
            echo 'Found $INTERFACE!'; 
            sudo ip link set $INTERFACE up;
            break; 
        fi
        sleep 1;
    done

    # 5. OVS Attach
    if ip link show $INTERFACE >/dev/null 2>&1; then
        sudo docker exec openvswitch_vswitchd ovs-vsctl add-port $BRIDGE $INTERFACE 2>/dev/null || true
        ip link show $INTERFACE
    else
        echo 'ERROR: Interface did not reappear. Reboot might be required.'
    fi
    "
    remote_exec "$CMD"
fi
