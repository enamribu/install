# shellcheck disable=SC2148
rescue --nomount
%pre

exec >/dev/pts/0 2>&1

download() {
    # axel 有问题
    # axel "https://rocky-linux-us-south1.production.gcp.mirrors.ctrliq.cloud/pub/rocky//8.7/BaseOS/aarch64/os/images/pxeboot/vmlinuz"
    # Initializing download: https://rocky-linux-us-south1.production.gcp.mirrors.ctrliq.cloud/pub/rocky//8.7/BaseOS/aarch64/os/images/pxeboot/vmlinuz
    # Connection gone.

    # axel https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.229-1/virtio-win-0.1.229.iso
    # Initializing download: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.229-1/virtio-win-0.1.229.iso
    # Too many redirects.

    # 先用 axel 下载
    [ -z $2 ] && save="" || save="-o $2"
    if ! axel $1 $save; then
        # 出错再用 curl
        [ -z $2 ] && save="-O" || save="-o $2"
        curl -L $1 $save
    fi
}

update_part() {
    partprobe
    partx -u $1
    udevadm settle
}

# 找到主硬盘
xda=$(lsblk -dn -o NAME | grep -E 'nvme0n1|.da')

# 反激活 lvm
vgchange -an

# 移除 lsblk 显示的分区
partx -d /dev/$xda

disk_size=$(blockdev --getsize64 /dev/$xda)
disk_2t=$((2 * 1024 * 1024 * 1024 * 1024))

# 对于红帽系是临时分区表，安装时除了 installer 分区，其他分区会重建为默认的大小
# 对于ubuntu是最终分区表，因为 ubuntu 的安装器不能调整个别分区，只能重建整个分区表
# {xda}*1 星号用于 nvme0n1p1 的字母 p
if [ -d /sys/firmware/efi ]; then
    # efi
    parted /dev/$xda -s -- \
        mklabel gpt \
        mkpart '" "' fat32 1MiB 1025MiB \
        mkpart '" "' ext4 1025MiB -2GiB \
        mkpart '" "' ext4 -2GiB 100% \
        set 1 boot on
    update_part /dev/$xda
    mkfs.fat -F 32 -n efi /dev/${xda}*1     #1 efi
    mkfs.ext4 -F -L os /dev/${xda}*2        #2 os
    mkfs.ext4 -F -L installer /dev/${xda}*3 #3 installer
elif [ "$disk_size" -ge "$disk_2t" ]; then
    # bios 2t
    parted /dev/$xda -s -- \
        mklabel gpt \
        mkpart '" "' ext4 1MiB 2MiB \
        mkpart '" "' ext4 2MiB -2GiB \
        mkpart '" "' ext4 -2GiB 100% \
        set 1 bios_grub on
    update_part /dev/$xda
    echo                                    #1 bios_boot
    mkfs.ext4 -F -L os /dev/${xda}*2        #2 os
    mkfs.ext4 -F -L installer /dev/${xda}*3 #3 installer
else
    # bios
    parted /dev/$xda -s -- \
        mklabel msdos \
        mkpart primary ext4 1MiB -2GiB \
        mkpart primary ext4 -2GiB 100% \
        set 1 boot on
    update_part /dev/$xda
    mkfs.ext4 -F -L os /dev/${xda}*1        #1 os
    mkfs.ext4 -F -L installer /dev/${xda}*2 #2 installer
fi
update_part /dev/$xda

# 挂载主分区
mkdir -p /os
mount /dev/disk/by-label/os /os

# 挂载其他分区
mkdir -p /os/boot/efi
mount /dev/disk/by-label/efi /os/boot/efi
mkdir -p /os/installer
mount /dev/disk/by-label/installer /os/installer

# 安装 grub2
basearch=$(uname -m)
if [ -d /sys/firmware/efi ]; then
    # el7的grub无法启动f38 arm的内核
    # https://forums.fedoraforum.org/showthread.php?330104-aarch64-pxeboot-vmlinuz-file-format-changed-broke-PXE-installs

    # shellcheck disable=SC2164
    cd /os/boot/efi
    download https://mirrors.aliyun.com/fedora/releases/38/Everything/$basearch/os/images/efiboot.img
    mkdir /efiboot
    mount -o ro efiboot.img /efiboot
    cp -r /efiboot/* /os/boot/efi/
else
    rpm -i --nodeps https://mirrors.aliyun.com/centos/7/os/x86_64/Packages/grub2-pc-modules-2.02-0.86.el7.centos.noarch.rpm
    grub2-install --boot-directory=/os/boot /dev/$xda
fi

# 安装 axel
rpm -i --nodeps https://mirrors.aliyun.com/epel/7/$basearch/Packages/a/axel-2.4-9.el7.$basearch.rpm

if [ -d /sys/firmware/efi ] && [ "$basearch" = "x86_64" ]; then
    action='efi'
fi

# 提取 finalos 到变量
eval "$(grep -o '\bfinalos\.[^ ]*' /proc/cmdline | sed 's/finalos.//')"

# 重新整理 extra，因为grub会处理掉引号，要重新添加引号
for var in $(grep -o '\bextra\.[^ ]*' /proc/cmdline | xargs); do
    extra_cmdline+=" $(echo $var | sed -E "s/(extra\.[^=]*)=(.*)/\1='\2'/")"
done

if [ -d /sys/firmware/efi ]; then
    grub_cfg=/os/boot/efi/EFI/BOOT/grub.cfg
else
    grub_cfg=/os/boot/grub2/grub.cfg
fi

# shellcheck disable=SC2154,SC2164
if [ "$distro" = "ubuntu" ]; then
    cd /os/installer/
    download $iso ubuntu.iso

    iso_file=/ubuntu.iso
    # 正常写法应该是 ds="nocloud-net;s=https://xxx/" 但是甲骨文云的ds更优先，自己的ds根本无访问记录
    # $seed 是 https://xxx/
    cat <<EOF >$grub_cfg
        set timeout=5
        menuentry "reinstall" {
            # https://bugs.launchpad.net/ubuntu/+source/grub2/+bug/1851311
            rmmod tpm
            search --no-floppy --label --set=root installer
            loopback loop $iso_file
            linux (loop)/casper/vmlinuz iso-scan/filename=$iso_file autoinstall cloud-config-url=$ks $extra_cmdline ---
            initrd (loop)/casper/initrd
        }
EOF
else
    cd /os/
    download $vmlinuz
    download $initrd

    cd /os/installer/
    download $squashfs install.img

    cat <<EOF >$grub_cfg
        set timeout=5
        menuentry "reinstall" {
            search --no-floppy --label --set=root os
            linux$action /vmlinuz inst.stage2=hd:LABEL=installer:/install.img inst.ks=$ks $extra_cmdline
            initrd$action /initrd.img
        }
EOF
fi
reboot
%end