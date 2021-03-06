#!/bin/bash

## Compilation of Instructions from Kolla Kubernetes Gate
## This is meant to set up Kolla Kubernetes All-In-One for CentOS-7
## Cinder iSCSI backend is used here
## Note that $1 will be the kube proxy IP, $2 will be the tunnel_interface, $3 will be the ext_interface_name,
## $4 will be the keepalived VIP, $5 will be the subnet size of the keepalived VIP network
## Lastly, $6 will take the value of master or minion (note that it will always be master for AIO)
## Note that keepalive runs on the same subnet as the "management" subnet, i.e. tunnel_interface
## The keepalived VIP should be an unused IP in the "management" subnet
## Run the script as root user

## Ensure that the required parameters are passed in
if [ "$#" -ne 6 ]
then
  echo "Please provide the following Information to the script:
       \$1 for kube proxy IP, i.e. management nic IP like 192.168.122.241
       \$2 for tunnel_interface, i.e. eth0
       \$3 for ext interface, i.e. eth1
       \$4 for keepalived VIP, i.e. unused IP on management NIC subnet like 192.168.122.254
       \$5 for subnet size of management network, i.e. 24
       \$6 for node type, i.e. master/minion"
  exit 1
fi


## Define Variables
kube_proxy_ip=$1
tunnel_interface=$2
ext_interface=$3
keepalived_vip=$4
mgmt_subnet_size=$5
node_type=$6


## Ensure that the specified interface exist and are UP on the system
function check_ifup {
    set -o pipefail # optional.
    /usr/sbin/ip address | grep $1 | grep -q "state UP"
}

function check_eth {
    if check_ifup $1;
    then
      echo "Interface $1 validated as UP."
    else
      echo "Please make sure interface $1 is present and UP before running the script."
      exit 1
fi
}

check_eth $tunnel_interface
check_eth $ext_interface


## Setup Host
echo "Setup Host"
sudo sed -i 's/enforcing/permissive/g' /etc/selinux/config
sudo yum install -y net-tools wget telnet
sudo yum install -y epel-release
sudo yum install -y python-pip
sudo yum install -y git gcc python-devel libffi-devel openssl-devel crudini jq
sudo pip install -U pip
sudo yum install -y ntp


## Install Ansible
echo "Install Ansible"
sudo yum install -y ansible


## Install OpenStack clients
echo "Install OpenStack clients"
sudo pip install python-openstackclient
sudo pip install python-neutronclient
sudo pip install python-cinderclient


## Turn off firewalld
echo "Turn off firewalld"
sudo systemctl stop firewalld
sudo systemctl disable firewalld


## Setup NTP
echo "Setup NTP"
sudo systemctl enable ntpd.service
sudo systemctl start ntpd.service


## Git Clone Kolla Ansible
echo "Git Clone Kolla Ansible"
sudo git clone http://github.com/openstack/kolla-ansible /opt/kolla-ansible


## Git Clone Kolla Kubernetes
echo "Git Clone Kolla Kubernetes"
sudo git clone http://github.com/openstack/kolla-kubernetes /opt/kolla-kubernetes


## Install kolla-ansible and kolla-kubernetes
echo "Install kolla-ansible and kolla-kubernetes"
sudo pip install -U /opt/kolla-ansible/ /opt/kolla-kubernetes/


## Copy default Kolla configuration to /etc
echo "Copy default Kolla configuration to /etc"
sudo cp -aR /usr/share/kolla-ansible/etc_examples/kolla /etc


## Copy default kolla-kubernetes configuration to /etc
echo "Copy default kolla-kubernetes configuration to /etc"
sudo cp -aR /opt/kolla-kubernetes/etc/kolla-kubernetes /etc


## Set Up Kubernetes
echo "Set Up Kubernetes"

# Assign apiserver-advertise-address
sudo mkdir -p /etc/nodepool/
echo $kube_proxy_ip | sudo tee --append /etc/nodepool/primary_node_private > /dev/null

cd /opt/kolla-kubernetes && tools/setup_kubernetes.sh $node_type

sudo yum install -y python-docker-py
sudo systemctl enable docker
sudo systemctl enable kubelet


## Setup Canal
echo "Setup Canal"
cd /opt/kolla-kubernetes && tests/bin/setup_canal.sh


## Untaint Master
echo "Untaint Master"
kubectl taint nodes --all=true node-role.kubernetes.io/master:NoSchedule-


## Setup Helm
echo "Setup Helm"
cd /opt/kolla-kubernetes && tools/setup_helm.sh


## Setup Loopback LVM for Cinder
echo "Setup Loopback LVM for Cinder"
/opt/kolla-kubernetes/tests/bin/setup_gate_loopback_lvm.sh


## Generate Default Passwords
echo "Generate Default Passwords"
sudo kolla-kubernetes-genpwd


## Create Kolla Namespace
echo "Create Kolla Namespace"
kubectl create namespace kolla


## Label the AIO node as the compute and controller node
echo "Label the AIO node as the compute and controller node"
kubectl label node $(hostname) kolla_compute=true
kubectl label node $(hostname) kolla_controller=true


## Add required Kolla Kubernetes configuration to the end of /etc/kolla/globals.yml
echo "Add required Kolla Kubernetes configuration to the end of /etc/kolla/globals.yml"
cat <<EOF > add-to-globals.yml
kolla_install_type: "source"
tempest_image_alt_id: "{{ tempest_image_id }}"
tempest_flavor_ref_alt_id: "{{ tempest_flavor_ref_id }}"

enable_heat: "no"
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
enable_cinder_backend_iscsi: "yes"
enable_cinder_backend_rbd: "no"
EOF
cat ./add-to-globals.yml | sudo tee -a /etc/kolla/globals.yml


## Generate the Kubernetes secrets and register them with Kubernetes
echo "Generate the Kubernetes secrets and register them with Kubernetes"
/opt/kolla-kubernetes/tools/secret-generator.py create


## Generate Default Configurations
echo "Generate Default Configurations"
cd /opt/kolla-kubernetes && ansible-playbook -e ansible_python_interpreter=/usr/bin/python -e @/etc/kolla/globals.yml -e @/etc/kolla/passwords.yml -e CONFIG_DIR=/etc/kolla ansible/site.yml


## Set libvirt type to QEMU
echo "Set libvirt type to QEMU"
sudo crudini --set /etc/kolla/nova-compute/nova.conf libvirt virt_type qemu
sudo crudini --set /etc/kolla/nova-compute/nova.conf libvirt cpu_mode none
sudo crudini --set /etc/kolla/keystone/keystone.conf cache enabled False


## Create and register Kolla config maps
echo "Create and register Kolla config maps"
kollakube res create configmap \
    mariadb keystone horizon rabbitmq memcached nova-api nova-conductor \
    nova-scheduler glance-api-haproxy glance-registry-haproxy glance-api \
    glance-registry neutron-server neutron-dhcp-agent neutron-l3-agent \
    neutron-metadata-agent neutron-openvswitch-agent openvswitch-db-server \
    openvswitch-vswitchd nova-libvirt nova-compute nova-consoleauth \
    nova-novncproxy nova-novncproxy-haproxy neutron-server-haproxy \
    nova-api-haproxy cinder-api cinder-api-haproxy cinder-backup \
    cinder-scheduler cinder-volume iscsid tgtd keepalived \
    placement-api placement-api-haproxy


## Enable resolv.conf workaround
echo "Enable resolv.conf workaround"
/opt/kolla-kubernetes/tools/setup-resolv-conf.sh kolla


## Build all Helm microcharts, service charts, and metacharts
echo "Build all Helm microcharts, service charts, and metacharts"
/opt/kolla-kubernetes/tools/helm_build_all.sh /tmp/


## Create cloud.yaml file for the deployment of the charts
echo "Create cloud.yaml file for the deployment of the charts"
cat <<EOF > /etc/kolla/cloud.yaml
global:
   kolla:
     all:
       docker_registry: docker.io
       image_tag: "4.0.0"
       kube_logger: false
       external_vip: $kube_proxy_ip
       base_distro: "centos"
       install_type: "source"
       tunnel_interface: $tunnel_interface
       resolve_conf_net_host_workaround: true
       kolla_kubernetes_external_subnet: $mgmt_subnet_size
       kolla_kubernetes_external_vip: $keepalived_vip
       kube_logger: false
     keepalived:
       all:
         api_interface: br-ex
     keystone:
       all:
         admin_port_external: "true"
         dns_name: $kube_proxy_ip
       public:
         all:
           port_external: "true"
     rabbitmq:
       all:
         cookie: 67
     glance:
       api:
         all:
           port_external: "true"
     cinder:
       api:
         all:
           port_external: "true"
       volume_lvm:
         all:
           element_name: cinder-volume
         daemonset:
           lvm_backends:
           - $kube_proxy_ip: 'cinder-volumes'
     ironic:
       conductor:
         daemonset:
           selector_key: "kolla_conductor"
     nova:
       placement_api:
         all:
           port_external: true
       novncproxy:
         all:
           host: $kube_proxy_ip
           port: 6080
           port_external: true
     openvswitch:
       all:
         add_port: true
         ext_bridge_name: br-ex
         ext_interface_name: $ext_interface
         setup_bridge: true
     horizon:
       all:
         port_external: true
EOF


## Set up OVS for the Infrastructure
echo "Set up OVS for the Infrastructure"
helm install /opt/kolla-kubernetes/helm/service/openvswitch --namespace kolla --name openvswitch --values /etc/kolla/cloud.yaml

# Ensure that OVS pod is up before proceeding
cd /opt/kolla-kubernetes && tools/wait_for_pods.sh kolla


## Bring up br-ex for keepalived to bind VIP to it
echo "Bring up br-ex for keepalived to bind VIP to it"
sudo ifconfig br-ex up

helm install /opt/kolla-kubernetes/helm/microservice/keepalived-daemonset --namespace kolla --name keepalived-daemonset --values /etc/kolla/cloud.yaml

# Ensure that keepalived pod is up before proceeding
cd /opt/kolla-kubernetes && tools/wait_for_pods.sh kolla


## Execute OpenStack Helm Charts in Phases
echo "Execute OpenStack Helm Charts in Phases"
helm install /opt/kolla-kubernetes/helm/service/mariadb --namespace kolla --name mariadb --values /etc/kolla/cloud.yaml

# Ensure that MariaDB pod is up before proceeding
cd /opt/kolla-kubernetes && tools/wait_for_pods.sh kolla

helm install /opt/kolla-kubernetes/helm/service/rabbitmq --namespace kolla --name rabbitmq --values /etc/kolla/cloud.yaml
helm install /opt/kolla-kubernetes/helm/service/memcached --namespace kolla --name memcached --values /etc/kolla/cloud.yaml
helm install /opt/kolla-kubernetes/helm/service/keystone --namespace kolla --name keystone --values /etc/kolla/cloud.yaml
helm install /opt/kolla-kubernetes/helm/service/glance --namespace kolla --name glance --values /etc/kolla/cloud.yaml
helm install /opt/kolla-kubernetes/helm/service/cinder-control --namespace kolla --name cinder-control --values /etc/kolla/cloud.yaml
helm install /opt/kolla-kubernetes/helm/service/cinder-volume-lvm --namespace kolla --name cinder-volume-lvm --values /etc/kolla/cloud.yaml
helm install /opt/kolla-kubernetes/helm/service/horizon --namespace kolla --name horizon --values /etc/kolla/cloud.yaml
helm install /opt/kolla-kubernetes/helm/service/neutron --namespace kolla --name neutron --values /etc/kolla/cloud.yaml

# Ensure that Neutron pod is up before proceeding
cd /opt/kolla-kubernetes && tools/wait_for_pods.sh kolla 600

helm install /opt/kolla-kubernetes/helm/service/nova-control --namespace kolla --name nova-control --values /etc/kolla/cloud.yaml
helm install /opt/kolla-kubernetes/helm/service/nova-compute --namespace kolla --name nova-compute --values /etc/kolla/cloud.yaml

# Ensure that nova control and nova compute pods are up before proceeding
cd /opt/kolla-kubernetes && tools/wait_for_pods.sh kolla 420

helm install /opt/kolla-kubernetes/helm/microservice/nova-cell0-create-db-job --namespace kolla --name nova-cell0-create-db-job --values /etc/kolla/cloud.yaml
helm install /opt/kolla-kubernetes/helm/microservice/nova-api-create-simple-cell-job --namespace kolla --name nova-api-create-simple-cell --values /etc/kolla/cloud.yaml


## Post Deployment
## Check that all pods are up and all jobs completed
cd /opt/kolla-kubernetes && tools/wait_for_pods.sh kolla

echo "Deployment is Completed"
echo "Generate openrc file"
/opt/kolla-kubernetes/tools/build_local_admin_keystonerc.sh ext
