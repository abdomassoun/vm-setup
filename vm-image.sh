#!/bin/bash

VM_COUNT=3
VM_NAME_PREFIX="testvm"
BASE_IMG="ubuntu-22.04-server-cloudimg-amd64.img"
BASE_URL="https://cloud-images.ubuntu.com/releases/22.04/release"
MEMORY=2048  # MB
VCPUS=2
DISK_SIZE=15G
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
  - nfs-kernel-server
  - nfs-common
  - curl
  - apt-transport-https
  - ca-certificates
  - gnupg
  - lsb-release
  - rsync
  - runc
  - skopeo
  - umoci
  - software-properties-common
  - buildah

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
  - modprobe br_netfilter

runcmd:
  - systemctl enable --now qemu-guest-agent

  # Apply sysctl settings
  - sysctl --system

  # Disable swap
  - swapoff -a
  - sed -i '/ swap / s/^/#/' /etc/fstab

  # Create keyring folder if it doesn't exist
  - mkdir -p -m 755 /etc/apt/keyrings

  # Add Kubernetes GPG key and repo
  - curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

  # Add CRI-O GPG key and repo
  - curl -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
  - echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v1.29/deb/ /" > /etc/apt/sources.list.d/cri-o.list

  # Install Kubernetes + CRI-O
  - apt-get update
  - apt-get install -y cri-o kubelet kubeadm kubectl
  - apt-mark hold kubelet kubeadm kubectl

  # Enable CRI-O
  - systemctl daemon-reexec
  - systemctl enable crio
  - systemctl start crio

  # Patch CRI-O runtime configuration
  - |
    sed -i 's/^default_runtime = "crun"/default_runtime = "runc"/' /etc/crio/crio.conf.d/10-crio.conf
    awk '/^\[crio\.runtime\]/ {print; print "enable_criu_support = true\n" "drop_infra_containers = true"; next}1' /etc/crio/crio.conf.d/10-crio.conf > /tmp/10-crio.conf && mv /tmp/10-crio.conf /etc/crio/crio.conf.d/10-crio.conf
  - systemctl restart crio

  # Reset kubeadm
  - kubeadm reset -f || true
  - apt-mark hold kubelet kubeadm kubectl

  # If controller node, initialize cluster
  - |
    if [ "${VM_NAME}" = "controller-node" ]; then
      kubeadm init --pod-network-cidr=10.244.0.0/16 --cri-socket=unix:///var/run/crio/crio.sock | tee /home/ubuntu/kubeadm-init.out
      mkdir -p /home/ubuntu/.kube
      cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
      chown ubuntu:ubuntu /home/ubuntu/.kube/config
      kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
    fi

  # Enable checkpointing in Kubelet
  - |
    sed -i 's|^KUBELET_KUBEADM_ARGS=.*|KUBELET_KUBEADM_ARGS="--container-runtime-endpoint=unix:///var/run/crio/crio.sock --feature-gates=ContainerCheckpoint=true --pod-infra-container-image=registry.k8s.io/pause:3.9"|' /var/lib/kubelet/kubeadm-flags.env
  - systemctl daemon-reexec
  - systemctl restart crio
  - systemctl restart kubelet

  # Setup NFS server on controller and mount on worker nodes
  - mkdir -p /mnt/nfs
  - |
    if [ "${VM_NAME}" = "controller-node" ]; then
      chown nobody:nogroup /mnt/nfs
      echo "/mnt/nfs 192.168.122.0/24(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
      exportfs -a
      systemctl restart nfs-kernel-server
      systemctl enable --now nfs-server
    else
      echo '192.168.122.101:/mnt/nfs /mnt/nfs nfs defaults 0 0' >> /etc/fstab
      mount -t nfs 192.168.122.101:/mnt/nfs /mnt/nfs
    fi

  # Add hostnames to /etc/hosts
  - echo "192.168.122.101  controller-node" >> /etc/hosts
  - echo "192.168.122.102  worker-node-1" >> /etc/hosts
  - echo "192.168.122.103  worker-node-2" >> /etc/hosts

  # Install Helm 
  - curl https://baltocdn.com/helm/signing.asc | gpg --dearmor -o /usr/share/keyrings/helm.gpg
  - echo "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" > /etc/apt/sources.list.d/helm-stable-debian.list
  - apt-get update
  - apt-get install -y helm
EOF

    echo "instance-id: $VM_NAME; local-hostname: $VM_NAME" > meta-data
    cloud-localds --network-config=network-config "$CLOUD_INIT_ISO" user-data meta-data

    echo "[*] Starting VM $VM_NAME"
    virt-install --connect qemu:///system \
        --name $VM_NAME \
        --memory $MEMORY \
        --vcpus $VCPUS \
        --disk path=$DISK_IMG,format=qcow2 \
        --disk path=$CLOUD_INIT_ISO,device=cdrom \
        --os-variant ubuntu20.04 \
        --virt-type kvm \
        --graphics none \
        --network network=default \
        --import \
        --noautoconsole
done
