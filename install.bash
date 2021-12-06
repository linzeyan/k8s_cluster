#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o xtrace
set -o pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH=${PATH}:/usr/local/bin

if [[ "${1:-init}" == "delete" ]]; then
    kubeadm reset
    iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
    ipvsadm -C
    kubectl delete node $(hostname)
    exit $?
fi

## Define variables
. /etc/os-release
OS="${NAME}_${VERSION_ID}"
baseDir='/vagrant'
netIF='enp0s8'
declare -i instanceNum=3
declare -i ipRange=100
clusterIPPrefix='192.168.56'
clusterName='vagrant'
VIP="${clusterIPPrefix}.$((9 + ${ipRange}))"
kubeVersion='1.22.4'
crioVersion='1.20'
timezone='Asia/Taipei'
cluster2spaces=''
cluster4spaces=''
etcdCluster79=''
for ((i = 1; i <= ${instanceNum}; i++)); do
    declare "node${i}"="${clusterIPPrefix}.$(($i + ${ipRange}))"
    eval "ip"="\$node${i}"
    if ! grep "${ip}  node${i}" /etc/hosts 2>&1 >/dev/null; then
        echo "${ip}  node${i}" >>/etc/hosts
    fi
    etcdCluster79="${etcdCluster79}https://${ip}:2379,"
    cluster2spaces="${cluster2spaces}  - \"node${i}\"\n  - \"${ip}\"\n"
    cluster4spaces="${cluster4spaces}    - \"node${i}\"\n    - \"${ip}\"\n"
done
eval ip="\$$(hostname)"
etcd2379=$(echo $etcdCluster79 | sed 's/,$//g')

## Replace BASH type variables with values
if grep 'perip2' ${baseDir}/conf/* 2>&1 >/dev/null; then
    echo 'Starting replace variable'
    sed -i "s/\${hostname}/$(hostname)/g" ${baseDir}/conf/*
    sed -i "s/\${ip}/${ip}/g" ${baseDir}/conf/*
    sed -i "s/\${VIP}/${VIP}/g" ${baseDir}/conf/*
    sed -i "s|\${etcd2379}|${etcd2379}|g" ${baseDir}/conf/*
    sed -i "s|\${netIF}|${netIF}|g" ${baseDir}/conf/*
    sed -i "s|\${kubeVersion}|${kubeVersion}|g" ${baseDir}/conf/*
    sed -i "s|\${clusterName}|${clusterName}|g" ${baseDir}/conf/*
    sed -i "s/\${perip2}/${cluster2spaces}/g" ${baseDir}/conf/*
    sed -i "s/\${perip4}/${cluster4spaces}/g" ${baseDir}/conf/*
fi

## Copy ssh keys
if [ ! -f ${HOME}/.ssh/config ]; then
    chown root:root ${baseDir}/ssh/*
    cp ${baseDir}/ssh/id_rsa ~/.ssh/
    cat ${baseDir}/ssh/id_rsa.pub >>${HOME}/.ssh/authorized_keys
    cp ${baseDir}/ssh/config ~/.ssh/
    chmod 600 ~/.ssh/*
fi

## Change time zone
if [[ "$(sudo timedatectl show | head -n 1 | awk -F= '{print $2}')" != "${timezone}" ]]; then
    echo 'Change time zone'
    sudo timedatectl set-timezone ${timezone}
fi

## Install dependent packages
if ! which ipvsadm 2>&1 >/dev/null; then
    echo 'Install dependent packages'
    sudo apt-get -qq update -y
    sudo apt-get -qq upgrade -y
    sudo apt-get -qq install -y \
        vim \
        git \
        cmake \
        build-essential \
        openvswitch-switch \
        tcpdump \
        unzip \
        nfs-common \
        chrony \
        jq \
        bash-completion \
        ipvsadm \
        libssl-dev
    ## Enable chronyd
    sudo systemctl enable --now chrony
    ## Disable swap
    echo 'disable swap'
    sudo swapoff -a
    sudo sed -i '/swap/s/^/#/' /etc/fstab
fi

if ! which crio 2>&1 >/dev/null; then
    echo 'Install crio'
    cat <<EOF | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/x${OS}/ /
EOF
    cat <<EOF | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:${crioVersion}.list
deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/${crioVersion}/x${OS}/ /
EOF

    curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/x${OS}/Release.key | sudo apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers.gpg add -
    curl -L https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:${crioVersion}/x${OS}/Release.key | sudo apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers-cri-o.gpg add -

    sudo apt-get -qq update
    sudo apt-get -qq install -y cri-o cri-o-runc
    sudo systemctl enable crio --now
fi

## Install module
if ! grep br_netfilter /etc/modules-load.d/modules.conf 2>&1 >/dev/null; then
    echo 'Install module'
    sudo modprobe -- ip_vs
    sudo modprobe -- ip_vs_rr
    sudo modprobe -- ip_vs_wrr
    sudo modprobe -- ip_vs_sh
    sudo modprobe -- nf_conntrack_ipv4 || sudo modprobe -- nf_conntrack
    sudo modprobe overlay
    sudo modprobe br_netfilter
    echo 'br_netfilter' >>/etc/modules-load.d/modules.conf
fi

## Enable ipv4 forward
if [ ! -f /etc/sysctl.d/kubernetes.conf ]; then
    echo 'Genreate sysctl config'
    sudo cat >/etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
vm.swappiness=0
vm.overcommit_memory=1
vm.panic_on_oom=0
fs.inotify.max_user_watches=89100
EOF
    ## Reload sysctl
    sudo sysctl --system
fi

## Install kubernetes
if ! which kubeadm 2>&1 >/dev/null; then
    sudo apt-get -qq install -y apt-transport-https curl
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
    echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee --append /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get -qq update
    sudo apt-get -qq install -y kubeadm=${kubeVersion}-00 kubelet=${kubeVersion}-00 kubectl=${kubeVersion}-00
    sudo systemctl enable --now kubelet
fi

## Install keepalived
if [ ! -f /etc/keepalived/keepalived.conf ]; then
    echo 'Install keepalived'
    sudo apt-get -qq install -y keepalived
    ## Generate keepalived config
    if [[ $(hostname) == "node${instanceNum}" ]]; then
        sed -i 's/state BACKUP/state MASTER/g' ${baseDir}/conf/keepalived.conf
        sed -i 's/priority 50/priority 100/g' ${baseDir}/conf/keepalived.conf
    fi
    sudo mkdir -p /etc/keepalived
    sudo cat ${baseDir}/conf/keepalived.conf >/etc/keepalived/keepalived.conf
    echo 'Enable keepalived'
    sudo systemctl enable --now keepalived
fi

## Add logrotate
rotateConfig='/etc/logrotate.d/k8s'
if [ ! -f ${rotateConfig} ]; then
    cat <<'k8s' >${rotateConfig}
/var/log/calico/*/*.log
/var/log/pods/*/*.log
/var/log/pods/*/*/*.log
{
    daily
    dateext
    rotate 52
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
k8s
fi

## Install kubernetes cluster
if [[ $(hostname) == "node${instanceNum}" ]]; then
    echo 'Cluster initial...'
    kubeadm init --config ${baseDir}/conf/kubeadm-config.yml --ignore-preflight-errors=all
    sudo mkdir -p ${HOME}/.kube
    sudo ln -sf /etc/kubernetes/admin.conf ${HOME}/.kube/config
    sudo chown $(id -u):$(id -g) ${HOME}/.kube/config
    kubectl completion bash >>${HOME}/.bashrc

    sed -i '/--port=0/d' /etc/kubernetes/manifests/kube-controller-manager.yaml /etc/kubernetes/manifests/kube-scheduler.yaml
    systemctl restart kubelet

    echo 'Sync k8s certs and config to other nodes'
    sshPort=$(ss -lntp | grep sshd | grep 0.0.0.0 | awk '{print $4}' | cut -d: -f2)
    for i in $(seq 1 $((${instanceNum} - 1))); do
        rsync -e "ssh -p ${sshPort}" -az \
            --exclude 'apiserver*' \
            --exclude 'front-proxy-client.*' \
            --exclude 'etcd/healthcheck-client.*' \
            --exclude 'etcd/peer.*' \
            --exclude 'etcd/server.*' \
            /etc/kubernetes/pki node${i}:/etc/kubernetes/
        rsync -e "ssh -p ${sshPort}" -az /etc/kubernetes/admin.conf node${i}:/etc/kubernetes
    done

    ## Install network
    echo 'Install Calico'
    if [[ -f ${baseDir}/addon/calico.yaml ]]; then
        kubectl apply -f ${baseDir}/addon/calico.yaml
    else
        kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
    fi

    echo 'Other nodes join'
    token=$(kubeadm token list | awk 'NR==2{print $1}')
    key=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
    for i in $(seq 1 $((${instanceNum} - 1))); do
        eval ip="\$node${i}"
        ssh -p ${sshPort} node${i} "kubeadm join ${VIP}:6443 --token ${token} \
                                        --discovery-token-ca-cert-hash sha256:${key} \
                                        --apiserver-advertise-address ${ip} \
                                        --control-plane --ignore-preflight-errors=all"
        sleep 10
        ssh -p ${sshPort} node${i} 'sed -i "/--port=0/d" /etc/kubernetes/manifests/kube-controller-manager.yaml /etc/kubernetes/manifests/kube-scheduler.yaml'
        ssh -p ${sshPort} node${i} 'systemctl restart kubelet'
        ssh -p ${sshPort} node${i} "sudo mkdir -p \${HOME}/.kube &&\
                                    sudo ln -sf /etc/kubernetes/admin.conf ~/.kube/config &&\
                                    sudo chown \$(id -u):\$(id -g) \${HOME}/.kube/config &&\
                                    kubectl completion bash >> ~/.bashrc"
    done
    kubectl taint nodes --all node-role.kubernetes.io/master-
fi
