#!/bin/bash

###########################################################################
#             My Arch-linux installation script                           #
# Hardware    : SATA SSD UEFI Desktop with AMD CPU                        #
# Encryption  : LVM on LUKS (FDE w/ encrypted swap but unencrypted /boot)#
# Bootloader  : systemd-boot                                              #
###########################################################################

encryption_passphrase="azerty"
root_password="azerty"
hostname="hostname"
user_name="user"
continent_city="Europe/Paris"
swap_size="2"
cpu_microcode="amd-ucode"

##################################
#### Check internet connection ###
##################################

ping -q -c1 archlinux.org > /dev/null
if [ $? != 0 ]; then echo "No internet connection. Try 'wifi-menu' and try again"; exit 1; fi

##########################################
### Zeroing and set up disk partitions ###
##########################################

timedatectl set-ntp true
pacman -Sy --noconfirm

# Wipe drive
sgdisk --zap-all /dev/sda

echo "Creating partition tables"
printf "n\n1\n4096\n+128M\nef00\nw\ny\n" | gdisk /dev/sda
printf "n\n2\n\n\n8e00\nw\ny\n" | gdisk /dev/sda

echo "Building EFI filesystem"
yes | mkfs.fat -F32 /dev/sda1

echo "Setting up cryptographic container (LUKS2)"
printf "%s" "$encryption_passphrase" | cryptsetup --type luks2 -h sha512 --pbkdf argon2id --label LVMPART luksFormat /dev/sda2
printf "%s" "$encryption_passphrase" | cryptsetup luksOpen /dev/sda2 cryptVol

echo "Setting up LVM"
pvcreate /dev/mapper/cryptVol
vgcreate Arch /dev/mapper/cryptVol
lvcreate -L +"$swap_size"GB Arch -n swap
lvcreate -l +100%FREE Arch -n root

echo "Building filesystems for root and swap"
yes | mkswap /dev/mapper/Arch-swap
yes | mkfs.ext4 /dev/mapper/Arch-root

echo "Mounting root & boot and enabling swap"
mount /dev/mapper/Arch-root /mnt
mkdir /mnt/boot
mount /dev/sda1 /mnt/boot
swapon /dev/mapper/Arch-swap

######################
#### Install Arch ####
######################
echo "Installing Arch Linux"
yes '' | pacstrap /mnt base linux linux-firmware $cpu_microcode efibootmgr wget networkmanager reflector lvm2 sudo

echo "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

###############################
#### Configure base system ####
###############################
echo "Configuring new system"
arch-chroot /mnt /bin/bash << EOF
echo "Setting system clock"
ln -sf /usr/share/zoneinfo/$continent_city /etc/localtime
hwclock --systohc --utc

echo "Setting locales"
echo "fr_FR.UTF-8 UTF-8" >> /etc/locale.gen
echo "LANG=fr_FR.UTF-8" >> /etc/locale.conf
locale-gen

echo "Setting french keyboard"
printf "KEYMAP=fr\n" >> /etc/vconsole.conf

echo "Setting hostname"
echo $hostname > /etc/hostname

echo "Setting root password"
echo -en "$root_password\n$root_password" | passwd

echo "Creating new user"
useradd -m -G wheel -s /bin/bash $user_name
echo -en "$root_password\n$root_password" | passwd $user_name

echo "Generating initramfs"
sed -i 's/^HOOKS.*/HOOKS=(base udev autodetect keyboard modconf block keymap encrypt lvm2 resume filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -p linux

echo "Setting up systemd-boot"
bootctl --path=/boot install

mkdir -p /boot/loader/
touch /boot/loader/loader.conf
tee -a /boot/loader/loader.conf << END
default arch
timeout 3
editor 0
END

mkdir -p /boot/loader/entries/
touch /boot/loader/entries/arch.conf
tee -a /boot/loader/entries/arch.conf << END
title ArchLinux
linux /vmlinuz-linux
initrd /$cpu_microcode.img
initrd /initramfs-linux.img
options cryptdevice=LABEL=LVMPART:cryptVol root=/dev/mapper/Arch-root resume=/dev/mapper/Arch-swap quiet rw
END

echo "Setting up Pacman hook for automatic systemd-boot updates"
mkdir -p /etc/pacman.d/hooks/
touch /etc/pacman.d/hooks/systemd-boot.hook
tee -a /etc/pacman.d/hooks/systemd-boot.hook << END
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Updating systemd-boot
When = PostTransaction
Exec = /usr/bin/bootctl update
END

echo "Enabling autologin"
mkdir -p /etc/systemd/system/getty@tty1.service.d/
touch /etc/systemd/system/getty@tty1.service.d/override.conf
tee -a /etc/systemd/system/getty@tty1.service.d/override.conf << END
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $user_name --noclear %I \$TERM
END

echo "Updating mirrors list"
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.BAK
reflector --latest 10 --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

touch /etc/pacman.d/hooks/mirrors-update.hook
tee -a /etc/pacman.d/hooks/mirrors-update.hook << END
[Trigger]
Operation = Upgrade
Type = Package
Target = pacman-mirrorlist

[Action]
Description = Updating pacman-mirrorlist with reflector
When = PostTransaction
Depends = reflector
Exec = /bin/sh -c "reflector --latest 10 --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist"
END

echo "Enabling periodic TRIM"
systemctl enable fstrim.timer

echo "Enabling NetworkManager"
systemctl enable NetworkManager

echo "Enabling suspend (but no hibernate)"
sed -i 's/#HandleLidSwitch=suspend/HandleLidSwitch=suspend/g' /etc/systemd/logind.conf

echo "Adding user as a sudoer"
echo '%wheel ALL=(ALL) ALL' | EDITOR='tee -a' visudo
EOF

# Demander GDM/autologin AVANT le umount
echo "Would you like to install GNOME desktop? (y/n)"
read response_desktop

if [ "$response_desktop" = "y" ]; then
    echo "Installing GNOME..."
    arch-chroot /mnt /bin/bash << EOF2
pacman -Sy --noconfirm gnome gdm
systemctl enable gdm

echo "Enable automatic login for $user_name?"
EOF2
    read response_autologin
    if [ "$response_autologin" = "y" ]; then
        mkdir -p /mnt/etc/gdm/
        tee -a /mnt/etc/gdm/custom.conf << END
[daemon]
AutomaticLogin=$user_name
AutomaticLoginEnable=True
END
        echo "Automatic login enabled for $user_name."
    fi
fi

umount -R /mnt
swapoff -a

echo "ArchLinux is ready. You can reboot now!"