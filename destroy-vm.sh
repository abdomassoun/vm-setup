#!/bin/bash

# Usage: ./destroy-vm.sh <vm-name>

VM_NAME="$1"

if [ -z "$VM_NAME" ]; then
    echo "Usage: $0 <vm-name>"
    exit 1
fi

echo "[*] Shutting down VM: $VM_NAME"
virsh --connect qemu:///system shutdown "$VM_NAME"

# Optional wait to give VM time to shut down
sleep 5

echo "[*] Undefining VM: $VM_NAME"
virsh --connect qemu:///system undefine "$VM_NAME"

echo "[*] Removing disk and cloud-init ISO"
rm -f "${VM_NAME}.qcow2" "${VM_NAME}-cidata.iso"
