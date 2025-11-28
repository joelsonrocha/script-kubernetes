#!/bin/bash
set -e

# ==============================================================================
# DEFINIÇÃO DE REDE (CRÍTICO PARA AWS)
# Define a rede interna dos Pods para 192.168.x.x para NÃO bater com 
# a rede da VPC da AWS (geralmente 172.x ou 10.x).
# ==============================================================================
POD_CIDR="192.168.0.0/16"

# ----------------------
# Funções de Utilidade
# ----------------------
error_exit() {
    echo "$1" 1>&2
    cleanup
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "Este script precisa ser executado como root."
    fi
}

# ----------------------
# Limpeza
# ----------------------
cleanup() {
    echo "Realizando limpeza..."

    # Remove instalação falha do Helm se existir
    helm uninstall cilium -n kube-system 2>/dev/null || true

    # Mata processos que usam a porta 6443 explicitamente (API server)
    if ss -ntlp | grep -q ':6443'; then
        echo "Porta 6443 está em uso. Matando processo..."
        PID=$(ss -ntlp | grep ':6443' | awk '{print $6}' | sed -E 's/.*pid=([0-9]+),.*/\1/')
        if [ -n "$PID" ]; then
            kill -9 $PID && echo "Processo $PID morto." || echo "Falha ao matar processo $PID."
        fi
    fi

    # Parar e resetar kubelet
    if systemctl is-active --quiet kubelet; then
        echo "Resetando cluster..."
        kubeadm reset -f || echo "Falha ao redefinir o Kubernetes."
        systemctl stop kubelet || echo "Falha ao parar o kubelet."
    fi

    # Remover pacotes e pastas
    apt-get remove -y --allow-change-held-packages kubeadm kubectl kubelet || true
    apt-get purge -y --allow-change-held-packages kubeadm kubectl kubelet || true
    apt-get autoremove -y

    rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni /var/lib/cni /var/lib/dockershim
    rm -f "$HOME/.kube/config"

    # Limpar interfaces de rede antigas do Cilium
    ip link delete cilium_host 2>/dev/null || true
    ip link delete cilium_net 2>/dev/null || true
    ip link delete cilium_vxlan 2>/dev/null || true

    echo "Limpeza concluída."
}

# ----------------------
# Configurações Iniciais
# ----------------------
disable_swap() {
    swapoff -a
    sed -i '/swap/d' /etc/fstab
}

open_firewall_ports() {
    if systemctl is-active --quiet ufw; then
        ufw allow 6443/tcp
        ufw allow 2379:2380/tcp
        ufw allow 10250/tcp
        # Cilium VXLAN port
        ufw allow 10259/tcp
        ufw allow 10257/tcp
        ufw allow 30000:32767/tcp
        ufw allow 8472/udp 
        ufw --force enable
    fi
}

install_kernel_modules() {
    cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
    modprobe overlay
    modprobe br_netfilter
}

configure_sysctl() {
    cat <<EOF | tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
    sysctl --system
}

enable_ip_forward() {
    echo 1 > /proc/sys/net/ipv4/ip_forward
}

# ----------------------
# Instalação de Dependências
# ----------------------
install_containerd() {
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y containerd.io
    cp -f /etc/containerd/config.toml /etc/containerd/config.toml.bkp 2>/dev/null || true
    mkdir -p /etc/containerd && containerd config default | tee /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    systemctl restart containerd
}

install_kubernetes_tools() {
    apt-get update
    # IMPORTANTE: Headers do kernel para Cilium eBPF
    apt-get install -y apt-transport-https ca-certificates curl linux-headers-$(uname -r)
    
    # K8s v1.34 (conforme solicitado)
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/trusted.gpg.d/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
    apt-get update
    apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
}

# ----------------------
# Cluster Kubernetes
# ----------------------
initialize_control_plane() {
    # Inicializa com CIDR específico para evitar conflito com AWS
    kubeadm init --pod-network-cidr=$POD_CIDR
}

configure_kubectl() {
    mkdir -p $HOME/.kube
    cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    chmod 600 $HOME/.kube/config
    export KUBECONFIG=$HOME/.kube/config
}

install_helm() {
    if ! command -v helm &> /dev/null; then
        echo "Instalando Helm..."
        curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
    else
        echo "Helm já instalado."
    fi
}

install_cilium_cni() {
    echo "Instalando Cilium 1.18.4..."
    
    # Remove instalação anterior que falhou (importante!)
    helm uninstall cilium -n kube-system 2>/dev/null || true

    helm repo add cilium https://helm.cilium.io/ 
    helm repo update

    # Instalação com a correção do kubeProxyReplacement (true ou false)
    helm install cilium cilium/cilium \
    --version 1.18.4 \
    --namespace kube-system \
    --set ipam.mode=cluster-pool \
    --set ipam.operator.clusterPoolIPv4PodCIDRList="{$POD_CIDR}" \
    --set kubeProxyReplacement=false

    echo "Aguardando Cilium iniciar..."
    kubectl -n kube-system rollout status ds/cilium --timeout=300s
    kubectl -n kube-system rollout status deployment/cilium-operator --timeout=300s
}

join_node_to_cluster() {
    read -rp "Comando de join: " join_command
    $join_command
}

# ----------------------
# Fluxo Principal
# ----------------------
echo "================================================="
echo " Instalação Kubernetes 1.34 + Cilium 1.18.4 (AWS)"
echo "================================================="
echo "1. Control Plane"
echo "2. Node"
echo "3. Limpar (Faça isso se deu erro antes)"
read -rp "Digite 1/2/3: " machine_type

case "$machine_type" in
    1)
        check_root
        disable_swap
        open_firewall_ports
        install_kernel_modules
        configure_sysctl
        install_containerd
        install_kubernetes_tools
        enable_ip_forward
        initialize_control_plane
        configure_kubectl
        install_helm
        install_cilium_cni
        ;;
    2)
        check_root
        disable_swap
        open_firewall_ports
        install_kernel_modules
        configure_sysctl
        install_containerd
        install_kubernetes_tools
        join_node_to_cluster
        ;;
    3)
        cleanup
        ;;
    *)
        error_exit "Escolha inválida."
        ;;
esac