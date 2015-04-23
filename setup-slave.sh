#!/bin/bash

# Disable Transparent Huge Pages (THP)
# THP can result in system thrashing (high sys usage) due to frequent defrags of memory.
# Most systems recommends turning THP off.
if [[ -e /sys/kernel/mm/transparent_hugepage/enabled ]]; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi

function partition_and_mount_device() {
    device=$(readlink -e $1)
    mount_point=$2

    mkdir -p $mount_point

    parted -s $device -- mklabel msdos mkpart primary linux-swap 0 "${SWAP_MB}MiB" mkpart primary ext2 "${SWAP_MB}Mib" -1s
    partprobe "$device"

    mkswap "${device}1"
    swapon "${device}1"

    mkfs.btrfs -O ^extref -f "${device}2"
    mount -o defaults,noatime,nodiratime "${device}2" $mount_point
}

# Make sure we are in the spark-ec2 directory
cd /root/spark-ec2

source ec2-variables.sh

# Set hostname based on EC2 private DNS name, so that it is set correctly
# even if the instance is restarted with a different private DNS name
PRIVATE_DNS=`wget -q -O - http://instance-data.ec2.internal/latest/meta-data/local-hostname`
hostname $PRIVATE_DNS
echo $PRIVATE_DNS > /etc/hostname
HOSTNAME=$PRIVATE_DNS  # Fix the bash built-in hostname variable too

instance_type=$(curl http://169.254.169.254/latest/meta-data/instance-type 2> /dev/null)
echo "Setting up slave on `hostname`... of type $instance_type"

# Work around for R3 or I2 instances without pre-formatted ext3 disks
device_mapping=$(curl http://169.254.169.254/latest/meta-data/block-device-mapping/ 2> /dev/null)
umount /mnt*
rm -rf /mnt*

yum install -q -y xfsprogs btrfs-progs parted

ephemeral_count=1
for label in ${device_mapping[*]}; do
  if [[ $label == ephemeral* ]]; then
    device="/dev/$(curl http://169.254.169.254/latest/meta-data/block-device-mapping/$label 2> /dev/null)"
    [[ $ephemeral_count == 1 ]] && mount_point="/mnt" || mount_point="/mnt$ephemeral_count"
    ((ephemeral_count++))

    partition_and_mount_device $device $mount_point    
  fi
done

# Mount options to use for ext3 and xfs disks (the ephemeral disks
# are ext3, but we use xfs for EBS volumes to format them faster)
XFS_MOUNT_OPTS="defaults,noatime,nodiratime,allocsize=8m"

function setup_ebs_volume {
  device=$1
  mount_point=$2
  if [[ -e $device ]]; then
    # Check if device is already formatted
    if ! blkid $device; then
      mkdir $mount_point
      if mkfs.xfs -q $device; then
        mount -o $XFS_MOUNT_OPTS $device $mount_point
        chmod -R a+w $mount_point
      else
        # mkfs.xfs is not installed on this machine or has failed;
        # delete /vol so that the user doesn't think we successfully
        # mounted the EBS volume
        rmdir $mount_point
      fi
    else
      # EBS volume is already formatted. Mount it if its not mounted yet.
      if ! grep -qs '$mount_point' /proc/mounts; then
        mkdir $mount_point
        mount -o $XFS_MOUNT_OPTS $device $mount_point
        chmod -R a+w $mount_point
      fi
    fi
  fi
}

# Format and mount EBS volume (/dev/sd[s, t, u, v, w, x, y, z]) as /vol[x] if the device exists
setup_ebs_volume /dev/sds /vol0
setup_ebs_volume /dev/sdt /vol1
setup_ebs_volume /dev/sdu /vol2
setup_ebs_volume /dev/sdv /vol3
setup_ebs_volume /dev/sdw /vol4
setup_ebs_volume /dev/sdx /vol5
setup_ebs_volume /dev/sdy /vol6
setup_ebs_volume /dev/sdz /vol7

# Alias vol to vol3 for backward compatibility: the old spark-ec2 script supports only attaching
# one EBS volume at /dev/sdv.
if [[ -e /vol3 && ! -e /vol ]]; then
  ln -s /vol3 /vol
fi

# Make data dirs writable by non-root users, such as CDH's hadoop user
chmod -R a+w /mnt*

# Remove ~/.ssh/known_hosts because it gets polluted as you start/stop many
# clusters (new machines tend to come up under old hostnames)
rm -f /root/.ssh/known_hosts

# Allow memory to be over committed. Helps in pyspark where we fork
echo 1 > /proc/sys/vm/overcommit_memory

# Add github to known hosts to get git@github.com clone to work
# TODO(shivaram): Avoid duplicate entries ?
cat /root/spark-ec2/github.hostkey >> /root/.ssh/known_hosts

# Create /usr/bin/realpath which is used by R to find Java installations
# NOTE: /usr/bin/realpath is missing in CentOS AMIs. See
# http://superuser.com/questions/771104/usr-bin-realpath-not-found-in-centos-6-5
echo '#!/bin/bash' > /usr/bin/realpath
echo 'readlink -e "$@"' >> /usr/bin/realpath
chmod a+x /usr/bin/realpath
