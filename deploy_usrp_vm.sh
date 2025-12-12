#!/bin/bash

# 1. Check Credentials
if [[ -z "$OS_AUTH_URL" ]]; then
    echo "Error: OpenStack credentials not loaded. Source 'admin-openrc.sh' or 'kolla-venv' first."
    exit 1
fi

IMAGE_NAME="ubuntu-24.04-uhd-ready"
FLAVOR="m1.small"
KEY_NAME="mykey"
SECURITY_GROUP="allow-all"

# 2. Detect Availability Zone
AZ_NAME=$(openstack availability zone list -f value -c "Zone Name" | head -n 1)
if [[ -z "$AZ_NAME" ]]; then AZ_NAME="nova"; fi

echo "=================================================="
echo "   USRP VM Deployment Wizard (Zone: $AZ_NAME)"
echo "=================================================="
echo ""
echo "Checking Compute Nodes (4 Pings each)..."
printf "%-20s %-15s %-10s %-20s\n" "Hostname" "IP" "OS-State" "Avg/Max Latency"
echo "-----------------------------------------------------------------------"

declare -a HOST_LIST
declare -a IP_LIST
INDEX=1

# 3. Ping Check Loop
while read -r HOST IP STATE; do
    LATENCY="N/A"
    if [[ "$STATE" == "up" ]]; then
        # Ping 4 times, wait max 1s per ping. Extract min/avg/max/mdev
        PING_STATS=$(ping -c 4 -W 1 "$IP" 2>/dev/null | tail -1 | awk -F '/' '{print $5 "/" $6}')
        if [[ -n "$PING_STATS" ]]; then
            LATENCY="${PING_STATS} ms"
        else
            LATENCY="Timeout"
        fi
    else
        STATE="DOWN"
    fi
    
    printf "%s) %-20s %-15s %-10s %-20s\n" "$INDEX" "$HOST" "$IP" "$STATE" "$LATENCY"
    
    HOST_LIST[$INDEX]=$HOST
    IP_LIST[$INDEX]=$IP
    ((INDEX++))
done < <(openstack hypervisor list --long -f value -c "Hypervisor Hostname" -c "Host IP" -c State | sort)

echo "-----------------------------------------------------------------------"
echo ""

# 4. Host Selection
echo "Which Host should run this VM?"
read -p "Select Host Number [1-$((INDEX-1))]: " HOST_CHOICE
SELECTED_HOST=${HOST_LIST[$HOST_CHOICE]}

if [[ -z "$SELECTED_HOST" ]]; then
    echo "Invalid selection."
    exit 1
fi

echo ""
echo "Selected Host: $SELECTED_HOST"
echo ""

# 5. USRP Selection
echo "Select USRP Network Setup:"
echo "  1) X310        (Network: usrp_private   Target: 192.168.40.2)"
echo "  2) N210        (Network: n210_private   Target: 10.0.53.2)"
echo "  3) N210-New    (Network: usrp_eno5_net  Target: 192.168.10.2)"
echo ""
read -p "Choice [1-3]: " USRP_CHOICE

if [[ "$USRP_CHOICE" == "1" ]]; then
    NET_NAME="usrp_private"
    TARGET_IP="192.168.40.2"
    PREFIX="X310"
elif [[ "$USRP_CHOICE" == "2" ]]; then
    NET_NAME="n210_private"
    TARGET_IP="10.0.53.2"
    PREFIX="N210"
elif [[ "$USRP_CHOICE" == "3" ]]; then
    NET_NAME="usrp_eno5_net"
    TARGET_IP="192.168.10.2"
    PREFIX="N210-New"
else
    echo "Invalid choice."
    exit 1
fi

# 6. Name Availability Check
while true; do
    echo ""
    read -p "Enter new VM Name (e.g., vm-test-1): " VM_NAME

    # Check if VM exists
    EXISTING_ID=$(openstack server show "$VM_NAME" -f value -c id 2>/dev/null)

    if [[ -n "$EXISTING_ID" ]]; then
        echo ""
        echo "WARNING: A VM named '$VM_NAME' already exists (ID: $EXISTING_ID)."
        echo "What do you want to do?"
        echo "  1) Delete existing VM and replace it"
        echo "  2) Enter a different name"
        echo "  3) Cancel"
        read -p "Choice [1-3]: " NAME_CHOICE

        if [[ "$NAME_CHOICE" == "1" ]]; then
            echo "Deleting '$VM_NAME'..."
            openstack server delete "$VM_NAME"
            
            # Robust Waiting Loop
            echo -n "Waiting for deletion to finish"
            # Loop runs as long as 'openstack server show' succeeds (exit code 0)
            while openstack server show "$VM_NAME" >/dev/null 2>&1; do
                echo -n "."
                sleep 2
            done
            echo ""
            echo "Deletion complete."
            sleep 2 # Safety pause to ensure Neutron ports are cleared
            break # Breaks the "while true" loop to proceed to creation
        elif [[ "$NAME_CHOICE" == "2" ]]; then
            continue  # Ask for name again
        else
            echo "Cancelled."
            exit 0
        fi
    else
        break # Name is free, proceed
    fi
done

echo ""
echo "Deploying '$VM_NAME'..."
echo " - Network: $NET_NAME ($PREFIX)"
echo " - Target : $SELECTED_HOST"

# 7. Inject USRP IP
cat <<EOF > /tmp/user_data_usrp.yml
#cloud-config
write_files:
  - path: /etc/usrp_ip
    content: "$TARGET_IP"
  - path: /etc/profile.d/usrp_env.sh
    content: |
      export USRP_IP=$TARGET_IP
runcmd:
  - echo "USRP Target IP set to $TARGET_IP"
EOF

# 8. Launch
openstack server create \
    --image "$IMAGE_NAME" \
    --flavor "$FLAVOR" \
    --network "$NET_NAME" \
    --key-name "$KEY_NAME" \
    --security-group "$SECURITY_GROUP" \
    --availability-zone "${AZ_NAME}:${SELECTED_HOST}" \
    --user-data /tmp/user_data_usrp.yml \
    "$VM_NAME"

rm /tmp/user_data_usrp.yml

echo ""
echo "VM '$VM_NAME' is building."
echo "Use './create_ssh_alias.sh' once it is ACTIVE."
