#!/bin/bash
set -e
# Função para exibir mensagens de erro e sair
error_exit() {
    echo "$1" 1>&2
    cleanup
    exit 1
}

# Verifica se o script é executado com permissões de root
if [ $EUID -ne 0 ]; then
    error_exit "Este script deve ser executado como root."
fi

# Função para desativar o swap
disable_swap() {
    swapoff -a || error_exit "Falha ao desativar o swap."
    sed -i '/swap/d' /etc/fstab || error_exit "Falha ao remover a entrada de swap do /etc/fstab."
}

# Função para verificar se o Containerd está em execução
check_containerd_running() {
    systemctl is-active --quiet containerd && return 0 || return 1
}

# Função para desfazer alterações em caso de erro
cleanup() {
    echo "Realizando limpeza..."

    # Verifica se o Containerd está rodando
    if check_containerd_running; then
        # Desfaz a configuração do Containerd apenas se houver backup
        if [ -f "/etc/containerd/config.toml.bkp" ]; then
            mv /etc/containerd/config.toml.bkp /etc/containerd/config.toml
            systemctl restart containerd || echo "Falha ao reiniciar o Containerd."
        fi
    else
        echo "Containerd não está em execução."
    fi

    # Desfaz a instalação do Kubernetes
    if systemctl is-active --quiet kubelet; then
        echo "Parando serviços do Kubernetes..."
        kubeadm reset -f || echo "Falha ao redefinir o Kubernetes."
        systemctl stop kubelet || echo "Falha ao parar o kubelet."
        systemctl stop docker || echo "Falha ao parar o Docker."

        echo "Removendo pacotes do Kubernetes..."
        #apt-get remove -y kubelet kubeadm kubectl || echo "Falha ao remover pacotes do Kubernetes."
        #apt-get purge -y kubelet kubeadm kubectl || echo "Falha ao purgar pacotes do Kubernetes."
        apt-get remove -y --allow-change-held-packages kubeadm kubectl kubelet || echo "Falha ao remover pacotes do Kubernetes."
        apt-get purge -y --allow-change-held-packages kubeadm kubectl kubelet || echo "Falha ao purgar pacotes do Kubernetes."
        rm -rf /etc/kubernetes || echo "Falha ao remover diretório /etc/kubernetes."
        rm -rf /var/lib/etcd || echo "Falha ao remover diretório /var/lib/etcd."
        rm -rf /var/lib/kubelet || echo "Falha ao remover diretório /var/lib/kubelet."
        rm -rf /etc/cni || echo "Falha ao remover diretório /etc/cni."
        rm -rf /var/lib/cni || echo "Falha ao remover diretório /var/lib/cni."
        rm -rf /var/lib/etcd || echo "Falha ao remover diretório /var/lib/etcd."
        rm -rf /var/lib/dockershim || echo "Falha ao remover diretório /var/lib/dockershim."
        rm -rf /etc/systemd/system/kubelet.service.d || echo "Falha ao remover diretório /etc/systemd/system/kubelet.service.d."

        echo "Atualizando pacotes..."
        apt-get update || echo "Falha ao atualizar pacotes."
    else
        echo "Kubelet não está em execução."
    fi

    # Verifica se a porta 6443 está em uso
    if ss -ntlp | grep -q ':6443'; then
        echo "Porta 6443 está em uso. Tentando parar o serviço kube-apiserver..."
        pkill kube-apiserver || echo "Falha ao parar o kube-apiserver."
    fi

    # Encerra o processo kube-scheduler se estiver em execução
    if ss -lptn 'sport = :10259' | grep kube-scheduler; then
        echo "Porta 10259 está em uso. Tentando parar o serviço kube-scheduler..."
        pkill kube-scheduler
        #sudo kill $(ss -lptn 'sport = :10259' | grep kube-scheduler | awk '{print $5}' | cut -d: -f1)
    fi

    local kube_config_file="$HOME/.kube/config"
    if [ -f "$kube_config_file" ]; then
        rm -f "$kube_config_file" || echo "Falha ao remover arquivo de configuração do kubectl."
    fi

     # Remove o kubectl utilizando dpkg
    #echo "Removendo kubectl..."
    #dpkg --purge --force-all kubectl || echo "Falha ao remover kubectl."

    #echo "Tentando corrigir dependências quebradas..."
    #apt --fix-broken install -y || echo "Falha ao corrigir dependências quebradas."

    echo "Limpeza concluída."
}


# Função para abrir as portas necessárias do firewall (UFW)
open_firewall_ports() {
    echo "Verificando e abrindo as portas necessárias no firewall..."

    # Verifica se o ufw está ativo
    if systemctl is-active --quiet ufw; then
        # Abre as portas necessárias para o Kubernetes
        ufw allow 6443/tcp || error_exit "Falha ao abrir a porta 6443."
        ufw allow 2379:2380/tcp || error_exit "Falha ao abrir as portas 2379-2380."
        ufw allow 10250/tcp || error_exit "Falha ao abrir a porta 10250."
        ufw allow 10259/tcp || error_exit "Falha ao abrir a porta 10259."
        ufw allow 10257/tcp || error_exit "Falha ao abrir a porta 10257."
        ufw allow 30000:32767/tcp || error_exit "Falha ao abrir as portas 30000-32767."
        ufw --force enable || error_exit "Falha ao habilitar o UFW."
    else
        echo "UFW não está ativo."
    fi

    echo "Portas abertas no firewall."
}

# Função para instalar os módulos do kernel necessários
install_kernel_modules() {
    echo "Instalando módulos do kernel necessários..."

    cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

    sudo modprobe overlay
    sudo modprobe br_netfilter

    echo "Módulos do kernel instalados."
}

# Função para configurar os parâmetros do sysctl
configure_sysctl() {
    echo "Configurando parâmetros do sysctl..."

    cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF

    sudo sysctl --system || error_exit "Falha ao recarregar configuração do sysctl."

    echo "Parâmetros do sysctl configurados."
}

# Função para instalar o Containerd
install_containerd() {
    # Instalação de pré-requisitos
    apt-get update || error_exit "Falha ao atualizar pacotes."
    apt-get install -y apt-transport-https ca-certificates curl gnupg --yes || error_exit "Falha ao instalar pré-requisitos."
    sudo install -m 0755 -d /etc/apt/keyrings || error_exit "Falha ao instalar pré-requisitos keyrings."

    # Adicionando o repositório do Docker
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o -y /etc/apt/keyrings/docker.gpg || error_exit "Falha ao baixar chave GPG."
    sudo chmod a+r /etc/apt/keyrings/docker.gpg || error_exit "Falha ao dar permissão para keyrings/docker.gpg."
    
    #echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable' | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null ||  error_exit "Falha ao configurar repositório Docker."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null ||  error_exit "Falha ao configurar repositório Docker."
   
   apt-get update || error_exit "Falha ao atualizar pacotes após adicionar repositório Docker."
    
    apt-get install -y containerd.io || error_exit "Falha ao instalar o Containerd."
    
    # Backup da configuração padrão do Containerd
    cp -f /etc/containerd/config.toml /etc/containerd/config.toml.bkp
    # Configuração padrão do Containerd
    #containerd config default | tee /etc/containerd/config.toml || error_exit "Falha ao configurar o Containerd."
    sudo mkdir -p /etc/containerd && containerd config default | sudo tee /etc/containerd/config.toml || error_exit "Falha ao configurar o Containerd."

    # Altera o arquivo de configuração para configurar o systemd cgroup driver
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml || error_exit "Falha ao alterar configuração do Containerd."

    # Reinicia o Containerd
    systemctl restart containerd || error_exit "Falha ao reiniciar o Containerd."

}

# Função para instalar kubeadm, kubelet e kubectl
install_kubernetes_tools() {
    apt-get update || error_exit "Falha ao atualizar pacotes."
    apt-get install -y apt-transport-https ca-certificates curl || error_exit "Falha ao instalar pré-requisitos para Kubernetes."

    # Download da chave pública do Repositório do Kubernetes
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --yes --dearmor -o /etc/apt/trusted.gpg.d/kubernetes-apt-keyring.gpg || error_exit "Falha ao baixar chave GPG do Kubernetes."

    # Adicionando o repositório apt do Kubernetes
    echo 'deb [signed-by=/etc/apt/trusted.gpg.d/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list || error_exit "Falha ao adicionar repositório Kubernetes."

    apt-get update || error_exit "Falha ao atualizar pacotes após adicionar repositório Kubernetes."
    apt-get install -y kubelet kubeadm kubectl || error_exit "Falha ao instalar kubeadm, kubelet e kubectl."
    
    # Impede atualizações automáticas
    apt-mark hold kubelet kubeadm kubectl || error_exit "Falha ao marcar versões do Kubernetes para evitar atualizações automáticas."
}

enable_ip_forward() {
    echo "Habilitando ip_forward..."
    echo 1 > /proc/sys/net/ipv4/ip_forward || error_exit "Falha ao habilitar ip_forward."
    echo "ip_forward habilitado."
}

# Função para inicializar o cluster Kubernetes como Control Plane
initialize_control_plane() {
    echo "Inicializando o cluster Kubernetes como Control Plane..."

    kubeadm init || error_exit "Falha ao inicializar o cluster Kubernetes."
    echo "O cluster Kubernetes foi inicializado com sucesso como Control Plane!"
    echo "Agora, execute os comandos abaixo em cada nó que deseja adicionar ao cluster:"
    echo "kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/calico.yaml"
    echo "kubeadm token create --print-join-command"
    echo "Em cada nó que deseja adicionar ao cluster, execute o comando fornecido pelo 'kubeadm token create'."
}

configure_kubectl(){
    # local kube_config_dir="$HOME/.kube"
    # local kube_config_file="$kube_config_dir/config"

    # # Cria o diretório .kube se não existir
    # mkdir -p "$kube_config_dir" || error_exit "Falha ao criar diretório .kube."

    # # Copia o arquivo de configuração do Kubernetes para o diretório do usuário
    # sudo cp -f /etc/kubernetes/admin.conf "$kube_config_file" || error_exit "Falha ao copiar arquivo de configuração do Kubernetes."

    # # Define as permissões adequadas para o diretório e arquivo
    # #sudo chown $(id -u):$(id -g) "$kube_config_dir" || error_exit "Falha ao configurar permissões do diretório .kube."
    # sudo chmod -R a+rwx "$kube_config_dir" || error_exit "Falha ao configurar permissões do diretório .kube."
    # #sudo chmod 644 "$kube_config_file" || error_exit "Falha ao configurar permissões do arquivo .kube/config."

    # # Define a variável de ambiente KUBECONFIG para o novo arquivo de configuração
    # export KUBECONFIG="$kube_config_file"

    # # Notificar sucesso (opcional)
    # echo "Configuração do kubectl realizada com sucesso!"


    sudo mkdir -p $HOME/.kube || error_exit "Falha ao criar diretório .kube."
    sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config || error_exit "Falha ao copiar arquivo para diretório .kube."
    #sudo chown $(id -u):$(id -g) "/.kube/config" || error_exit "Falha ao dar permissão .kube."
    sudo chmod o+rw "$HOME/.kube/config"
    export KUBECONFIG="$HOME/.kube/config" || error_exit "Falha ao exportar KUBECONFIG"

    echo "Configuração do kubectl realizada com sucesso!"
}

# Função para juntar o node ao cluster Kubernetes
join_node_to_cluster() {
    echo "Juntando esta máquina como node ao cluster Kubernetes..."
    echo "Digite o comando fornecido pelo 'kubeadm token create' após inicializar o Control Plane."
    read -rp "Comando de join: " join_command

    # Executa o comando de join
    $join_command || error_exit "Falha ao juntar o node ao cluster Kubernetes."

    echo "Node adicionado ao cluster Kubernetes com sucesso!"
}

echo "Bem-vindo ao script de instalação do Kubernetes!"

# Pergunta se a máquina será um Control Plane ou node
echo "Por favor, escolha o tipo de máquina:"
echo "1. Control Plane"
echo "2. Node"
echo "3. Clear Kubernetes Instalation"
read -rp "Digite 1 ou 2 ou 3: " machine_type

# Função para inicializar o cluster Kubernetes
# initialize_kubernetes_cluster() {
#     # Comando de inicialização do cluster
#     echo "Execute o seguinte comando APENAS NA MÁQUINA QUE SERÁ O CONTROL PLANE:"
#     echo "kubeadm init"

#     # Configura o kubectl
#     mkdir -p $HOME/.kube || error_exit "Falha ao criar diretório .kube."
#     cp -i /etc/kubernetes/admin.conf $HOME/.kube/config || error_exit "Falha ao copiar arquivo de configuração do Kubernetes."
#     chown $(id -u):$(id -g) $HOME/.kube/config || error_exit "Falha ao configurar permissões do arquivo .kube/config."
# }

# Função para instalar o CNI (Calico)
install_calico_cni() {
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/calico.yaml || error_exit "Falha ao aplicar manifest do Calico."
}


# Direciona para as etapas adequadas com base na escolha
if [ "$machine_type" = "1" ]; then
    disable_swap || error_exit "Falha ao desativar o swap."
    open_firewall_ports || error_exit "Falha ao abrir as portas necessárias no firewall."
    install_kernel_modules  || error_exit "Falha ao instalar módulos do kernel."
    configure_sysctl || error_exit "Falha ao configurar parâmetros do sysctl."
    install_containerd || error_exit "Falha ao instalar o Containerd."
    install_kubernetes_tools || error_exit "Falha ao instalar ferramentas do Kubernetes."
    enable_ip_forward
    #initialize_kubernetes_cluster || error_exit "Falha ao inicializar o cluster Kubernetes."
    initialize_control_plane
    configure_kubectl
    # sleep 30s
    install_calico_cni || error_exit "Falha ao instalar o CNI (Calico)."
    # echo "Aguardando 30 segundos..."
    # sleep 30s
    # echo "Configurando o kubectl"
    # configure_kubectl || error_exit "Erro ao configurar kubectl"
    # echo "Fim..."
    
elif [ "$machine_type" = "2" ]; then
    disable_swap || error_exit "Falha ao desativar o swap."
    open_firewall_ports || error_exit "Falha ao abrir as portas necessárias no firewall."
    install_kernel_modules  || error_exit "Falha ao instalar módulos do kernel."
    configure_sysctl || error_exit "Falha ao configurar parâmetros do sysctl."
    install_containerd || error_exit "Falha ao instalar o Containerd."
    install_kubernetes_tools || error_exit "Falha ao instalar ferramentas do Kubernetes."
    join_node_to_cluster
elif [ "$machine_type" = "3" ]; then
    cleanup
else
    error_exit "Escolha inválida. Por favor, execute o script novamente e digite 1 - Control-plane ou 2 - node."
fi

# Script principal
# main() {
#     disable_swap || error_exit "Falha ao desativar o swap."
#     open_firewall_ports || error_exit "Falha ao abrir as portas necessárias no firewall."
#     install_kernel_modules  || error_exit "Falha ao instalar módulos do kernel."
#     configure_sysctl || error_exit "Falha ao configurar parâmetros do sysctl."
#     install_containerd || error_exit "Falha ao instalar o Containerd."
#     install_kubernetes_tools || error_exit "Falha ao instalar ferramentas do Kubernetes."
#     initialize_kubernetes_cluster || error_exit "Falha ao inicializar o cluster Kubernetes."
#     install_calico_cni || error_exit "Falha ao instalar o CNI (Calico)."

#     echo "Cluster Kubernetes instalado e configurado com sucesso!"
# }

#main
#cleanup