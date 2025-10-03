#!/bin/bash
set -e

# ----------------------
# Funções de Utilidade
# ----------------------
error_exit() {
    echo "$1" 1>&2
    cleanup
    exit 1
}

check_containerd_running() {
    systemctl is-active --quiet containerd && return 0 || return 1
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

    # Mata processos que usam a porta 6443 explicitamente (API server)
    if ss -ntlp | grep -q ':6443'; then
        echo "Porta 6443 está em uso. Matando processo que usa a porta..."
        PID=$(ss -ntlp | grep ':6443' | awk '{print $6}' | sed -E 's/.*pid=([0-9]+),.*/\1/')
        if [ -n "$PID" ]; then
            kill -9 $PID && echo "Processo $PID morto." || echo "Falha ao matar processo $PID."
        else
            echo "Não foi possível identificar o PID da porta 6443."
        fi
    else
        echo "Porta 6443 livre."
    fi

    # Continua com as demais rotinas que você já tem...

    # Parar e resetar kubelet
    if systemctl is-active --quiet kubelet; then
        echo "Parando serviços do Kubernetes..."
        kubeadm reset -f || echo "Falha ao redefinir o Kubernetes."
        systemctl stop kubelet || echo "Falha ao parar o kubelet."
    fi

    # Remover pacotes, arquivos e diretórios do Kubernetes
    apt-get remove -y --allow-change-held-packages kubeadm kubectl kubelet || echo "Falha ao remover pacotes do Kubernetes."
    apt-get purge -y --allow-change-held-packages kubeadm kubectl kubelet || echo "Falha ao purgar pacotes do Kubernetes."

    rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni /var/lib/cni /var/lib/dockershim /etc/systemd/system/kubelet.service.d

    # Remover arquivo de configuração do kubectl no usuário
    local kube_config_file="$HOME/.kube/config"
    if [ -f "$kube_config_file" ]; then
        rm -f "$kube_config_file" || echo "Falha ao remover arquivo de configuração do kubectl."
    fi

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
        ufw allow 10259/tcp
        ufw allow 10257/tcp
        ufw allow 30000:32767/tcp
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
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y containerd.io
    cp -f /etc/containerd/config.toml /etc/containerd/config.toml.bkp
    mkdir -p /etc/containerd && containerd config default | tee /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    systemctl restart containerd
}

install_kubernetes_tools() {
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl
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
    kubeadm init
}

configure_kubectl() {
    mkdir -p $HOME/.kube
    cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    chmod 600 $HOME/.kube/config
    export KUBECONFIG=$HOME/.kube/config
}

install_calico_cni() {
    # Versão compatível com K8s 1.34
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
}

install_dashboard() {
    echo "Instalando Kubernetes Dashboard..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF
    echo "Dashboard instalado. Execute:"
    echo "  kubectl proxy"
    echo "Depois acesse:"
    echo "  http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
    echo "Token:"
    echo "  kubectl -n kubernetes-dashboard create token admin-user"
}

join_node_to_cluster() {
    read -rp "Comando de join: " join_command
    $join_command
}

# ----------------------
# Fluxo Principal
# ----------------------
echo "Escolha o tipo de máquina:"
echo "1. Control Plane"
echo "2. Node"
echo "3. Limpar"
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
        install_calico_cni
        # install_dashboard
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
