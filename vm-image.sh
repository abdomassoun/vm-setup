#!/bin/bash

VM_COUNT=2
VM_NAME_PREFIX="testvm"
BASE_IMG="ubuntu-22.04-server-cloudimg-amd64.img"
BASE_URL="https://cloud-images.ubuntu.com/releases/22.04/release"
MEMORY=2048  # MB
VCPUS=2
DISK_SIZE=10G
IP_BASE="192.168.122"
IP_START=100

# Download base image
if [ ! -f $BASE_IMG ]; then
    wget "${BASE_URL}/${BASE_IMG}"
fi

for i in $(seq 1 $VM_COUNT); do
    if [ $i -eq 1 ]; then
        VM_NAME="controller-node"
    else
        INDEX=$((i - 1))
        VM_NAME="worker-node${INDEX}"
    fi

    IP=$((IP_START + i ))
    VM_IP="${IP_BASE}.${IP}"

    DISK_IMG="${VM_NAME}.qcow2"
    CLOUD_INIT_ISO="${VM_NAME}-cidata.iso"

    echo "[*] Creating disk for $VM_NAME"
    qemu-img create -f qcow2 -b $BASE_IMG -F qcow2 $DISK_IMG $DISK_SIZE

        echo "[*] Generating network-config for $VM_NAME $VM_IP"
    cat > network-config <<EOF
version: 2
ethernets:
  enp1s0:
    dhcp4: false
    addresses:
      - ${VM_IP}/24
    gateway4: 192.168.122.1
    nameservers:
      addresses: [8.8.8.8]
EOF

        # Cloud-init user-data
cat > user-data <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true

users:
  - name: ubuntu
    plain_text_passwd: "ubuntu"
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL

ssh_pwauth: true
disable_root: false

packages:
  - qemu-guest-agent
  - criu
  - nfs-common
  - curl
  - apt-transport-https
  - ca-certificates
  - gnupg
  - lsb-release
  - containerd

write_files:
  - path: /etc/sysctl.d/99-k8s.conf
    content: |
      net.bridge.bridge-nf-call-ip6tables = 1
      net.bridge.bridge-nf-call-iptables = 1
      net.ipv4.ip_forward = 1
  - path: /etc/hosts
    content: |
      127.0.0.1 localhost
      127.0.1.1 ${VM_NAME}

      192.168.122.101  controller-node
      192.168.122.102  worker-node-1
      192.168.122.103  worker-node-2

bootcmd:
  - cloud-init-per once ifdown ifdown ens3
  - cloud-init-per once bugfix rm /run/network/interfaces.d/ens3
  - cloud-init-per once ifup ifup ens3
  - modprobe br_netfilter

runcmd:
  - systemctl enable --now qemu-guest-agent

  # Apply sysctl settings
  - sysctl --system
  # Disable swap

  - swapoff -a
  - sed -i '/ swap / s/^/#/' /etc/fstab

  # Containerd setup
  - mkdir -p /etc/containerd
  - containerd config default | tee /etc/containerd/config.toml
  - systemctl restart containerd
  - systemctl enable containerd

  # Create keyring folder if it doesn't exist
  - mkdir -p -m 755 /etc/apt/keyrings

  # Add Kubernetes GPG key and repo (v1.32)
  - curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
  - chmod 644 /etc/apt/sources.list.d/kubernetes.list

  # Install Kubernetes tools
  - apt-get update
  - apt-get install -y kubelet kubeadm kubectl
  - apt-mark hold kubelet kubeadm kubectl

  # Optional: Auto-configure kubectl if hostname is 'controller'
  - |
    if [ "$(hostname)" = "controller" ]; then
      mkdir -p /home/ubuntu/.kube
      cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
      chown ubuntu:ubuntu /home/ubuntu/.kube/config
    fi

  # Mount NFS (replace with your server IP)
  - mkdir -p /mnt/nfs
  - mount -t nfs 62.171.148.24 :/mnt/nfs /mnt/nfs
  - echo '62.171.148.24 :/mnt/nfs /mnt/nfs nfs defaults 0 0' >> /etc/fstab

  - echo "192.168.122.101  controller-node" >> /etc/hosts
  - echo "192.168.122.102  worker-node-1" >> /etc/hosts
  - echo "192.168.122.103  worker-node-2" >> /etc/hosts
EOF
# Meta-data (can be minimal)
    echo "instance-id: $VM_NAME; local-hostname: $VM_NAME" > meta-data

    # Create ISO with cloud-init
    cloud-localds --network-config=network-config "$CLOUD_INIT_ISO" user-data meta-data

    # Start the VM
    echo "[*] Starting VM $VM_NAME"
    virt-install --connect qemu:///system \
        --name $VM_NAME \
        --memory $MEMORY \
        --vcpus $VCPUS \
        --disk path=$DISK_IMG,format=qcow2 \
        --disk path=$CLOUD_INIT_ISO,device=cdrom \
        --os-type linux \
        --os-variant ubuntu20.04 \
        --virt-type kvm \
        --graphics none \
        --network network=default \
        --import \
        --noautoconsole
done
