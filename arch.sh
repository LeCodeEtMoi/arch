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


##################################
#### UEFI & NVME SSD detection ###
##################################
efivar -l >/dev/null 2>&1

if [[ $? -eq 0 ]] && lsblk | grep -q "sda"; then
    echo "Welcome to my custom Arch install script"
else
    echo "It's a very bad idea to run a script without read it. The current script only support UEFI PC w/ NVME SSD"
    exit 1;
fi

##########################################
### Zeroing and set up disk partitions ###
##########################################

# Update system clock
timedatectl set-ntp true

# Sync packages database
pacman -Sy --noconfirm

# Wipe drive
sgdisk --zap-all /dev/sda

echo "Creating partition tables"
printf "n\n1\n4096\n+128M\nef00\nw\ny\n" | gdisk /dev/sda1 # partition 1 : ESP/EFI, 128Mo, flag=$ef00 (boot), starting sector = 4096o
printf "n\n2\n\n\n8e00\nw\ny\n" | gdisk /dev/sda2 #partition 2 : linux partition, flag $8300, size remaining

echo "Building EFI filesystem"
yes | mkfs.fat -F32 /dev/nvme0n1p1 #format EPS partition in FAT32

echo "Setting up cryptographic container (LUKS2)"
echo "cypher : aes-xts-plain64 (default)"
echo "hash : sha512"
echo "key size : 2*256 (so XTS-AES 256) (default)"
echo "PBKDF : argon2id"

printf "%s" "$encryption_passphrase" | cryptsetup --type luks2 -h sha512 --pbkdf argon2id --label LVMPART luksFormat /dev/nvme0n1p2
printf "%s" "$encryption_passphrase" | cryptsetup luksOpen /dev/nvme0n1p2 cryptVol

echo "Setting up LVM"
pvcreate /dev/mapper/cryptVol # creation of 1 physical volume : cryptVol
vgcreate Arch /dev/mapper/cryptVol # creation of 1 physical volume group
lvcreate -L +"$swap_size"GB Arch -n swap #swap logical volume
lvcreate -l +100%FREE Arch -n root #root logicial volume

echo "Building filesystems for root and swap"
yes | mkswap /dev/mapper/Arch-swap
yes | mkfs.ext4 /dev/mapper/Arch-root

echo "Mounting root & boot and enabling swap"
mount /dev/mapper/Arch-root /mnt
mkdir /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot
swapon /dev/mapper/Arch-swap


######################
#### Install Arch ####
######################
echo "Installing Arch Linux"
yes '' | pacstrap /mnt base linux linux-firmware $cpu_microcode efibootmgr wget networkmanager reflector lvm2 sudo #reflector is a script for mirrors ranking 

echo "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab


###############################
#### Configure base system ####
###############################
echo "Configuring new system"
arch-chroot /mnt /bin/bash << EOF #this trick is used to execute following line on the new system
echo "Setting system clock"
ln -sf /usr/share/zoneinfo/$continent_city /etc/localtime
hwclock --systohc --localtime

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
#sed -i 's/^MODULES.*/MODULES=(ext4)/' /etc/mkinitcpio.conf
mkinitcpio -p linux

echo "Setting up systemd-boot"
bootctl --path=/boot install

mkdir -p /boot/loader/
touch /boot/loader/loader.conf
tee -a /boot/loader/loader.conf << END
default arch
timeout 0
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
mkdir -p  /etc/systemd/system/getty@tty1.service.d/
touch /etc/systemd/system/getty@tty1.service.d/override.conf
tee -a /etc/systemd/system/getty@tty1.service.d/override.conf << END
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $user_name --noclear %I $TERM
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

umount -R /mnt
swapoff -a

#######
# IHM #
#######

# Poser une question à l'utilisateur et stocker sa réponse dans la variable "response"
echo "Would you like to enable automatic login with GDM? (y/n)"
read response

# Vérifier si la réponse de l'utilisateur est "y" (oui)
if [ "$response" = "y" ]; then
    # Afficher un avertissement
    echo "Warning: Do not attempt to do this for users managed by systemd-homed. This is currently not implemented and will crash GDM."
    
    # Demander le nom d'utilisateur
    echo "Please enter your user_name:"
    read user_name
    
    # Ajouter la configuration à /etc/gdm/custom.conf
    echo "# Enable automatic login for user" | sudo tee -a /etc/gdm/custom.conf > /dev/null
    echo "[daemon]" | sudo tee -a /etc/gdm/custom.conf > /dev/null
    echo "AutomaticLogin=$user_name" | sudo tee -a /etc/gdm/custom.conf > /dev/null
    echo "AutomaticLoginEnable=True" | sudo tee -a /etc/gdm/custom.conf > /dev/null
    
    echo "Automatic login has been enabled for user $user_name."
else
    # Si la réponse est différente de "y", afficher "Ok"
    echo "Ok, automatic login has not been enabled."
fi

#Installation d'un systeme de bureau
echo "Would you like a GNOME ? (y/n)"
read response



# 1 3 6 1417 23 25 28 29 40 45 54 55




echo "ArchLinux is ready. You can reboot now!"
