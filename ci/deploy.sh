#!/bin/bash

# Deploy script to install provisioning server for OPNFV Apex
# author: Dan Radez (dradez@redhat.com)
# author: Tim Rozet (trozet@redhat.com)
#
# Based on RDO Manager http://www.rdoproject.org
#
# Pre-requisties:
#  - Supports 3 or 4 network interface configuration
#  - Target system must be RPM based
#  - Provisioned nodes expected to have following order of network connections (note: not all have to exist, but order is maintained):
#    eth0- admin network
#    eth1- private network (+storage network in 3 NIC config)
#    eth2- public network
#    eth3- storage network
#  - script assumes /24 subnet mask

set -e

##VARIABLES
declare -i CNT
declare UNDERCLOUD

##FUNCTIONS

##verify vm exists, an has a dhcp lease assigned to it
##params: none 
function setup_instack_vm {
  if ! virsh list | grep instack > /dev/null; then
      #virsh vol-create default instack.qcow2.xml
      virsh define instack.xml

      #Upload instack image
      #virsh vol-create default --file instack.qcow2.xml
      virsh vol-create-as default instack.qcow2 30G --format qcow2
      virsh vol-upload --pool default --vol instack.qcow2 --file instack.qcow2

      sleep 1 # this was to let the copy settle, needed with vol-upload?

      virsh start instack
  else
      echo "Found Instack VM, using existing VM"
  fi
  
  sleep 3 # let DHCP happen

  CNT=10
  echo -n "Waiting for instack's dhcp address"
  while ! grep instack /var/lib/libvirt/dnsmasq/default.leases > /dev/null && [ $CNT -gt 0 ]; do
      echo -n "."
      sleep 3
      CNT=CNT-1
  done

  # get the instack VM IP
  UNDERCLOUD=$(grep instack /var/lib/libvirt/dnsmasq/default.leases | awk '{print $3}')

  CNT=10
  echo -en "\rValidating instack VM connectivity"
  while ! ping -c 1 $UNDERCLOUD > /dev/null && [ $CNT -gt 0 ]; do
      echo -n "."
      sleep 3
      CNT=CNT-1
  done
  CNT=10
  while ! ssh -T -o "StrictHostKeyChecking no" "root@$UNDERCLOUD" "echo ''" 2>&1> /dev/null && [ $CNT -gt 0 ]; do
      echo -n "."
      sleep 3
      CNT=CNT-1
  done

  # extra space to overwrite the previous connectivity output
  echo -e "\rInstack VM has IP $UNDERCLOUD                                    "

  #ssh -T -o "StrictHostKeyChecking no" root@$UNDERCLOUD "systemctl stop openstack-nova-compute.service"
  #ssh -T -o "StrictHostKeyChecking no" root@$UNDERCLOUD "ip a a 192.0.2.1/24 dev eth1"
  ssh -T -o "StrictHostKeyChecking no" root@$UNDERCLOUD "if ! ip a s eth1 | grep 192.0.2.1; then ip a a 192.0.2.1/24 dev eth1; fi"
}

function setup_virtual_baremetal {
  for i in 0 1; do
    if ! virsh list | grep baremetal_${i} > /dev/null; then
      virsh define baremetal_${i}.xml
      virsh vol-create-as default baremetal_${i}.qcow2 40G --format qcow2
    fi
  done
}

##Copy over the glance images and instack json file
##params: none 
function copy_materials {

  scp -o "StrictHostKeyChecking no" stack/deploy-ramdisk-ironic.initramfs "stack@$UNDERCLOUD":
  scp -o "StrictHostKeyChecking no" stack/deploy-ramdisk-ironic.kernel "stack@$UNDERCLOUD":
  scp -o "StrictHostKeyChecking no" stack/discovery-ramdisk.initramfs "stack@$UNDERCLOUD":
  scp -o "StrictHostKeyChecking no" stack/discovery-ramdisk.kernel "stack@$UNDERCLOUD":
  scp -o "StrictHostKeyChecking no" stack/fedora-user.qcow2 "stack@$UNDERCLOUD":
  scp -o "StrictHostKeyChecking no" stack/overcloud-full.initrd "stack@$UNDERCLOUD":
  scp -o "StrictHostKeyChecking no" stack/overcloud-full.qcow2 "stack@$UNDERCLOUD":
  scp -o "StrictHostKeyChecking no" stack/overcloud-full.vmlinuz "stack@$UNDERCLOUD":

  if [ $virtual == "TRUE" ]; then
      scp instackenv-virt.json "stack@$UNDERCLOUD":instackenv.json
  else
      scp instackenv.json "stack@$UNDERCLOUD":
  fi
}

##preping it for deployment and launch the deploy
##params: none 
function undercloud_prep_overcloud_deploy {

### TODO: REMOVE THIS HACK
### RDO manager is not setting this parameter.
### once RDO manager does set it properly we can remove this ssh call
  ssh -T -o "StrictHostKeyChecking no" "root@$UNDERCLOUD" <<EOI
if ! grep -e "^service_plugins" /etc/neutron/neutron.conf; then
    openstack-config --set /etc/neutron/neutron.conf DEFAULT service_plugins "neutron.services.l3_router.l3_router_plugin.L3RouterPlugin,neutron.services.metering.metering_plugin.MeteringPlugin"
    service neutron-server restart
    echo "WARNING: updated /etc/neutron/neutron.conf DEFAULT service_plugins"
fi
EOI

  ssh -T -o "StrictHostKeyChecking no" "stack@$UNDERCLOUD" <<EOI
source stackrc
echo "Uploading overcloud glance images"
openstack overcloud image upload
echo "Configuring undercloud and discovering nodes"
openstack baremetal import --json instackenv.json
openstack baremetal configure boot
openstack baremetal introspection bulk start
echo "Configuring flavors"
openstack flavor create --id auto --ram 4096 --disk 40 --vcpus 1 baremetal
openstack flavor set --property "cpu_arch"="x86_64" --property "capabilities:boot_option"="local" baremetal
echo "Configuring nameserver on ctlplane network"
neutron subnet-update \$(neutron subnet-list | grep -v id | grep -v \\\\-\\\\- | awk {'print \$2'}) --dns-nameserver 8.8.8.8
echo "Executing overcloud deployment"
openstack overcloud deploy --templates
EOI

}

display_usage() {
  echo -e "\n\n${blue}This script is used to deploy the Apex Installer and Provision OPNFV Target System${reset}\n\n"
  echo -e "\n${green}Make sure you have the latest kernel installed before running this script! (yum update kernel +reboot)${reset}\n"
  echo -e "\nUsage:\n$0 [arguments] \n"
  echo -e "\n   -no_parse : No variable parsing into config. Flag. \n"
  echo -e "\n   -base_config : Full path of settings file to parse. Optional.  Will provide a new base settings file rather than the default.  Example:  -base_config /opt/myinventory.yml \n"
  echo -e "\n   -virtual : Node virtualization instead of baremetal. Flag. \n"
  echo -e "\n   -enable_virtual_dhcp : Run dhcp server instead of using static IPs.  Use this with -virtual only. \n"
  echo -e "\n   -static_ip_range : static IP range to define when using virtual and when dhcp is not being used (default), must at least a 20 IP block.  Format: '192.168.1.1,192.168.1.20' \n"
  echo -e "\n   -ping_site : site to use to verify IP connectivity from the VM when -virtual is used.  Format: -ping_site www.blah.com \n"
  echo -e "\n   -floating_ip_count : number of IP address from the public range to be used for floating IP. Default is 20.\n"
}

##translates the command line paramaters into variables
##params: $@ the entire command line is passed
##usage: parse_cmd_line() "$@"
parse_cmdline() {
  if [[ ( $1 == "--help") ||  $1 == "-h" ]]; then
    display_usage
    exit 0
  fi

  echo -e "\n\n${blue}This script is used to deploy the Apex Installer and Provision OPNFV Target System${reset}\n\n"
  echo "Use -h to display help"
  sleep 2

  while [ "`echo $1 | cut -c1`" = "-" ]
  do
    echo $1
    case "$1" in
        -base_config)
                base_config=$2
                shift 2
            ;;
        -no_parse)
                no_parse="TRUE"
                shift 1
            ;;
        -virtual)
                virtual="TRUE"
                shift 1
            ;;
        -enable_virtual_dhcp)
                enable_virtual_dhcp="TRUE"
                shift 1
            ;;
        -static_ip_range)
                static_ip_range=$2
                shift 2
            ;;
        -ping_site)
                ping_site=$2
                shift 2
            ;;
        -floating_ip_count)
                floating_ip_count=$2
                shift 2
            ;;
        *)
                display_usage
                exit 1
            ;;
    esac
  done

  if [ ! -z "$enable_virtual_dhcp" ] && [ ! -z "$static_ip_range" ]; then
    echo -e "\n\n${red}ERROR: Incorrect Usage.  Static IP range cannot be set when using DHCP!.  Exiting${reset}\n\n"
    exit 1
  fi

  if [ -z "$virtual" ]; then
    if [ ! -z "$enable_virtual_dhcp" ]; then
      echo -e "\n\n${red}ERROR: Incorrect Usage.  enable_virtual_dhcp can only be set when using -virtual!.  Exiting${reset}\n\n"
      exit 1
    elif [ ! -z "$static_ip_range" ]; then
      echo -e "\n\n${red}ERROR: Incorrect Usage.  static_ip_range can only be set when using -virtual!.  Exiting${reset}\n\n"
      exit 1
    fi
  fi

  if [ -z "$floating_ip_count" ]; then
    floating_ip_count=20
  fi
}

##END FUNCTIONS

main() {
  parse_cmdline "$@"
  setup_instack_vm
  if [ $virtual == "TRUE" ]; then
    setup_virtual_baremetal
  fi
  copy_materials
  undercloud_prep_overcloud_deploy
}

main "$@"
