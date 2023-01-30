#!/bin/bash
# August 2022, cec@dbi-services;
# pre-requisite system-level tasks to be executed as root once on each new machine;

# load common parameters;
# assume the global_parameters file exists in same directory as the current script, which can be called from anywhere;
local_dir=$(pwd $(cd $(dirname $0)))
if [[ ! -f ${local_dir}/global_parameters ]]; then
   echo "${local_dir}/global_parameters not found, aborting ..."
   exit 1
fi
. ${local_dir}/global_parameters

# set the hostname;
hostname ${dctm_machine}.${dctm_domain}
echo ${dctm_machine} > /etc/hostname
domainname ${dctm_domain}
hostname

# perform some editing in the /etc/hosts file;
# comment out spurious 127.* addresses but keep only the loopback one;
# append database server's host to hosts file if needed;
# append the ip address of the machine's first network interface, which must therefore have been configured properly;
cp /etc/hosts /tmp/.
sed -i -E -e 's/^(127(.([0-9]{1,3})){3}).+$/#\0/' -e '$a127.0.0.1 localhost.localdomain localhost' -e "\$a$(hostname -I) ${dctm_machine}.${dctm_domain} ${dctm_machine} cs" -e "\$a${db_server_host_ip_address} ${db_server_host_alias}" /etc/hosts
diff /etc/hosts /tmp
ping -c 3 cs
hostname --fqdn
dnsdomainname

# alternatively to a local oracle account with public key installed on the remote db machine for passwordless authentication, we use sshpass instead;
# it's a bit controversial but OK in a development environment;
# pick one of the commands below, depending on whether running under a RedHat derivative (yum) or Ubuntu one (apt);
#yum install sshpass -y
apt install sshpass -y

# Oracle stuff;
# Oracle client software is delivered as zip-compressed files;
#yum install unzip.x86_64 -y
apt install unzip -y

# to be verified on RH linux;
apt install libaio1 -y

# Documentum prerequisites, cf. documentation;
# pick one of the commands below, depending on whether running under a RedHat derivative (yum) or Ubuntu one (apt);
echo "Installing Documentum prerequisites"
#yum install tcl -y
#yum install expect -y
apt install tcl -y
apt install expect -y
# if under a RedHat derivative such as Oracle Linux;
#ln -s /usr/lib64/libsasl2.so.3.0.0 /usr/lib64/libsasl2.so.2

#yum install gawk -y
apt install gawk -y

# if under Ubuntu;
apt install curl -y

# permanent modification in sysctl.conf to stay across system reboots;
# if applicable, i.e. O/S on bare metal or VM; not for shared kernel environments such as OCI or Linux containers; in those environment, these changes need to be applied to the host's kernel;
#cp /etc/sysctl.conf /tmp/.
#sed -E -i 's/^(kernel.shmmni.+=[^0-9])+[0-9]+/\16500/' /etc/sysctl.conf
#diff /etc/sysctl.conf /tmp

# dynamic modification in sysctl so no need to reboot immediately;
#sysctl -w kernel.shmmni=16500
#sysctl -a | grep shmmni
#sysctl -p

#cp /etc/security/limits.conf /tmp
#sed -E -i "/End of file/i ${dctm_owner}          -       core            -1" /etc/security/limits.conf
#diff /etc/security/limits.conf /tmp
#echo "Please, close and restart all ${dctm_owner}'s sessions to actualize its new limits"

# create ${dctm_owner}/${dctm_owner} account;
cp /etc/passwd /tmp/.
cp /etc/group /tmp/.
useradd --shell /bin/bash --password $(perl -e 'print crypt($ARGV[0], "password")' ${dctm_password}) --create-home ${dctm_owner}
usermod --append --groups=${dctm_owner} ${dctm_owner}
diff /etc/passwd /tmp
diff /etc/group /tmp

# make it sudoer with no password needed;
# remove the file /etc/sudoers.d/dmadmin to revoke this privilege;
echo "${dctm_owner} ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers.d/${dctm_owner}

# create or mount sub-directory for binaries and give ownership to $dctm_owner;
# if the ${binaries_root} already exists, this step is skipped;
# therefore, if a mounted volume must be used, it must be mounted beforehand;
# if ${binaries_root} does not exist, it is created under / which generally speaking is not a good idea;
if [[ ! -d ${binaries_root} ]]; then
   mkdir -p ${binaries_root}
   chown ${dctm_owner}:${dctm_owner} ${binaries_root}
fi

