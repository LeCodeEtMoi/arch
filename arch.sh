#!/bin/bash

###########################################################################
# 			        My Arch-linux installation script                     #
#                                                                         #
# Hardware    : SDA plus (NVME SSD UEFI Laptop with Intel+Nvidia GPU  )              #
# Encryption  : LVM on LUKS (FDE w/ encrypted swap but unencrypted /boot) #
# 		LUKS  : --cypher=aes-xts-plain64 --pbkdf=argon2id                 #
# 		LVM   : 2 * Ext4 volumes (/ & swap)                               #
#                                                                         #
# Bootloader  : systemd-boot                                              #
###########################################################################

ping -c 3 archlinux.org

timedatectl set-ntp true
timedatectl status

fdisk /dev/sda

mkfs.fat -F32 /dev/sda1       # partition EFI en FAT32
mkfs.ext4 /dev/sda2           # partition root en ext4
mount /dev/sda2 /mnt         # monter la partition root
mkdir -p /mnt/boot
mount /dev/sda1 /mnt/boot    # monter la partition EFI
pacstrap /mnt base linux linux-firmware
genfstab -U /mnt >> /mnt/etc/fstab
cat /mnt/etc/fstab
arch-chroot /mnt
loadkeys fr
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
echo "monpc" > /etc/hostname
echo "CONFIGURATION FICHIER HOST"
nano /etc/hosts
passwd
useradd -m -G wheel maitre
passwd maitre


# 1 3 6 1417 23 25 28 29 40 45 54 55




# echo "ArchLinux is ready. You can reboot now!"
