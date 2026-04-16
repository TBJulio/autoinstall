#!/bin/bash
set -e

#user input
echo "1 - Arch
2 - Debian"
read -p "Select the number for the OS you are currently using for this script: " OS_NUM
echo ""
case "$OS_NUM" in
	1)
		echo "Running Arch autoinstallation..."
		OS=arch
		;;
	2)
		echo "Running Debian autoinstallation..."
		OS=debian
		#Root reminder
		if [ "$EUID" -ne 0 ]; then
			echo "Please run as root"
			exit 1
		fi
		;;
	*)
		echo "Invalid option"
		echo "Currently only supporting Arch and Debian"
		exit 1
		;;
esac
echo ""
read -p "Set a Username: " USER_NAME
echo ""
read -s -p "Set a User Password: " USER_PASS
echo ""
read -s -p "Set a Root Password: " ROOT_PASS
echo ""

if [ "$OS" = "debian" ]; then
	apt install -y debootstrap arch-install-scripts dosfstools btrfs-progs parted
fi

#Selecting drive
lsblk
echo ""
read -p "Enter the drive used for this installation (/dev/sda or /dev/nvme0n1): " TARGET_DRIVE
if [ ! -b "$TARGET_DRIVE" ]; then
	echo "Error: $TARGET_DRIVE is not a valid drive. Exiting"
	exit 1
fi
read -p "WARNING: All data on $TARGET_DRIVE will be deleted. Do you want to continue? Type 'yes' to continue: " CONFIRMATION
if [ "$CONFIRMATION" != "yes" ]; then
	echo "Installation cancelled"
	exit 1
fi

#Naming Partitions
if [[ $TARGET_DRIVE == *"nvme"* ]]; then
	PART_EFI="${TARGET_DRIVE}p1"
	PART_SWAP="${TARGET_DRIVE}p2"
	PART_ROOT="${TARGET_DRIVE}p3"
else
	PART_EFI="${TARGET_DRIVE}1"
	PART_SWAP="${TARGET_DRIVE}2"
	PART_ROOT="${TARGET_DRIVE}3"
fi

#Partitioning
parted -s "$TARGET_DRIVE" mklabel gpt

#EFI-512MB
parted -s "$TARGET_DRIVE" mkpart "EFI" fat32 1MB 513MB
parted -s "$TARGET_DRIVE" set 1 esp on
#Swap-8GB
parted -s "$TARGET_DRIVE" mkpart "swap" linux-swap 513MB 8.5GB
#Root-Rest
parted -s "$TARGET_DRIVE" mkpart "root" btrfs 8.5GB 100%
udevadm settle

#Formating
mkfs.vfat -F 32 "$PART_EFI"
mkswap "$PART_SWAP"
mkfs.btrfs -f "$PART_ROOT"

#Subvolumes
mount -o subvolid=5 "$PART_ROOT" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@srv
case "$OS" in
	arch)
		btrfs subvolume create /mnt/@pkg
		;;
	debian)
		btrfs subvolume create /mnt/@apt
		;;
	*)
		echo "Invalid option"
		echo "Currently only supporting Arch and Debian"
		exit 1
		;;
esac
btrfs subvolume create /mnt/@snapshots
umount /mnt

#Mounting
BTRFS_CONFIG="noatime,compress=zstd:5,space_cache=v2,commit=300"
mount -o $BTRFS_CONFIG,subvol=@ "$PART_ROOT" /mnt
mkdir -p /mnt/{boot/efi,home,var/log,srv,snapshots}
case "$OS" in
	arch)
		mkdir -p /mnt/var/cache/pacman/pkg
		;;
	debian)
		mkdir -p /mnt/var/cache/apt/archives
		;;
	*)
		echo "Invalid option"
		echo "Currently only supporting Arch and Debian"
		exit 1
		;;
esac
mount -o $BTRFS_CONFIG,subvol=@home "$PART_ROOT" /mnt/home
mount -o $BTRFS_CONFIG,subvol=@snapshots "$PART_ROOT" /mnt/snapshots
mount -o nodatacow,subvol=@log "$PART_ROOT" /mnt/var/log
mount -o commit=300,space_cache=v2,noatime,compress=no,subvol=@srv "$PART_ROOT" /mnt/srv
case "$OS" in
	arch)
		mount -o nodatacow,subvol=@pkg "$PART_ROOT" /mnt/var/cache/pacman/pkg
		;;
	debian)
		mount -o nodatacow,subvol=@apt "$PART_ROOT" /mnt/var/cache/apt/archives
		;;
	*)
		echo "Invalid option"
		echo "Currently only supporting Arch and Debian"
		exit 1
		;;
esac
mount "$PART_EFI" /mnt/boot/efi
swapon "$PART_SWAP"

#Base System
case "$OS" in
	arch)
		pacstrap /mnt base linux linux-firmware intel-ucode nvidia-utils nvidia-settings btrfs-progs sudo nano fastfetch networkmanager grub efibootmgr git
		genfstab -U /mnt >> /mnt/etc/fstab

		arch-chroot /mnt /bin/bash <<-EOF

		systemctl enable NetworkManager

		ln -sf /usr/share/zoneinfo/America/Mexico_City /etc/localtime
		hwclock --systohc
		sed -i 's/^#es_MX.UTF-8 UTF-8/es_MX.UTF-8 UTF-8/' /etc/locale.gen
		locale-gen

		echo "rig-arch" > /etc/hostname

		grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch
		grub-mkconfig -o /boot/grub/grub.cfg

		echo "root:$ROOT_PASS" | chpasswd
		useradd -m -G wheel $USER_NAME
		echo "$USER_NAME:$USER_PASS" | chpasswd
		echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

		exit
		EOF
		;;
	debian)
		debootstrap sid /mnt https://deb.debian.org/debian
		genfstab -U /mnt | tee /mnt/etc/fstab
		sed -i 's/subvolid=[0-9]*,//g' /mnt/etc/fstab
		arch-chroot /mnt /bin/bash <<-EOF

		export DEBIAN_FRONTEND=noninteractive
		echo 'keyboard-configuration  keyboard-configuration/layoutcode string us' | debconf-set-selections
		echo 'keyboard-configuration  keyboard-configuration/modelcode string pc105' | debconf-set-selections
		echo 'locales locales/default_environment_locale select es_MX.UTF-8' | debconf-set-selections
		apt-get update
		apt-get -y install linux-image-amd64 locales
		ln -sf /usr/share/zoneinfo/America/Mexico_City /etc/localtime
		hwclock --systohc
		sed -i 's/^#es_MX.UTF-8 UTF-8/es_MX.UTF-8 UTF-8/' /etc/locale.gen
		locale-gen

		echo "rig-debian" > /etc/hostname

		apt install -y grub-efi-amd64 efibootmgr
		grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian
		update-grub

		apt install -y network-manager
		systemctl enable NetworkManager

		apt install -y sudo nano git btrfs-progs fastfetch

		echo "root:$ROOT_PASS" | chpasswd
		useradd -m -G sudo -s /bin/bash $USER_NAME
		echo "$USER_NAME:$USER_PASS" | chpasswd

		exit
		EOF
		;;
	*)
		echo "Invalid option"
		echo "Currently only supporting Arch and Debian"
		exit 1
		;;
esac

#Snapshoting
SNAP_DIR="/mnt/snapshots/minimal-install"
mkdir "$SNAP_DIR"
btrfs subvolume snapshot -r /mnt "$SNAP_DIR/root"
btrfs subvolume snapshot -r /mnt/home "$SNAP_DIR/home"
btrfs subvolume snapshot -r /mnt/srv "$SNAP_DIR/srv"
btrfs subvolume snapshot -r /mnt/var/log "$SNAP_DIR/log"
case "$OS" in
	arch)
		btrfs subvolume snapshot -r /mnt/var/cache/pacman/pkg "$SNAP_DIR/pkg"
		;;
	debian)
		btrfs subvolume snapshot -r /mnt/var/cache/apt/archives "$SNAP_DIR/apt"
		;;
	*)
		echo "Invalid option"
		echo "Currently only supporting Arch and Debian"
		exit 1
		;;
esac

umount -R /mnt
reboot
