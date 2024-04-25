# Kubernetes Script

## Isto é um script para criar um cluster kubernetes rodando apenas um simples comando:
```
sudo ./kubernetes.sh
```


Foi testado no ubuntu server 22.04

A instalação é feita usando o kubeadm e instala o kubernets 1.29

Depois de instalado, você pode testar usando o comando:
```
sudo kubectl get nodes -o wide
```

caso queira acessar o kubectl sem sudo, pode rodar isto:
```
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```
e caso queira usar apenas um nó, sendo o control-plane executando pods, pode usar este comando:
```
kubectl taint nodes ubuntu node-role.kubernetes.io/control-plane:NoSchedule-
```

# Quem quiser colaborar, melhorar ou sugerir algo, é só abrir um PR.
