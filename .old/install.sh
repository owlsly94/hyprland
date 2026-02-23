#!/bin/bash

# 1. Configure pacman.conf (Misc Options & Multilib)
echo "Beautifying pacman.conf..."
sudo sed -i 's/^#Color/Color\nILoveCandy/' /etc/pacman.conf
sudo sed -i 's/^#CheckSpace/CheckSpace/' /etc/pacman.conf
sudo sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
sudo sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf

# Enable Multilib
sudo sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf

# 2. Add Chaotic-AUR
echo "Configuring Chaotic-AUR..."
sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
sudo pacman-key --lsign-key 3056513887B78AEB
sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'

if ! grep -q "\[chaotic-aur\]" /etc/pacman.conf; then
    echo -e "\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist" | sudo tee -a /etc/pacman.conf
fi

# 3. Optimize Mirrors with rate-mirrors
echo "Installing rate-mirrors from Chaotic-AUR..."
sudo pacman -Sy --noconfirm rate-mirrors

echo "Rating mirrors (this may take a minute)..."
rate-mirrors --protocol https arch --max-delay 3600 | sudo tee /etc/pacman.d/mirrorlist

# 4. Sync and Install Yay + Apps
echo "Installing yay and resolving conflicts..."
sudo pacman -Sy --noconfirm --ask 4 yay

if [ -f "apps.txt" ]; then
    echo "Installing apps from apps.txt..."
    yay -S --noconfirm --ask 4 --needed - < apps.txt
else
    echo "apps.txt not found, skipping app installation."
fi

# 5. CPU Governor Rules & Service
echo "Setting up CPU Performance Governor..."
sudo tee /etc/udev/rules.d/99-cpu-governor.rules <<EOF
ACTION=="add", SUBSYSTEM=="cpu", KERNEL=="cpu[0-9]*", ATTR{cpufreq/scaling_governor}="performance"
EOF

sudo udevadm control --reload-rules && sudo udevadm trigger
echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

sudo tee /etc/systemd/system/cpu-governor.service <<EOF
[Unit]
Description=Set CPU Governor to Performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now cpu-governor.service

# 6. Libvirt Configuration
echo "Configuring Libvirt..."
sudo sed -i 's/^#unix_sock_group = "libvirt"/unix_sock_group = "libvirt"/' /etc/libvirt/libvirtd.conf
sudo sed -i 's/^#unix_sock_rw_perms = "0770"/unix_sock_rw_perms = "0770"/' /etc/libvirt/libvirtd.conf

sudo systemctl enable --now libvirtd.service
sudo usermod -a -G libvirt $USER

# 7. SDDM Autologin Configuration
echo "Configuring SDDM Autologin for $USER..."
sudo tee /etc/sddm.conf <<EOF
[Autologin]
User=$USER
Session=hyprland
EOF

# 8. Steam Download Optimization (steam_dev.cfg)
echo "Applying Steam download optimizations..."
mkdir -p "$HOME/.steam/steam/"
cat <<EOF > "$HOME/.steam/steam/steam_dev.cfg"
@nClientDownloadEnableHTTP2PlatformLinux 0
@fDownloadRateImprovementToAddAnotherConnection 1.0
EOF

# 9. Download Dotfiles using npx degit
echo "Installing Node.js for dotfile deployment..."
sudo pacman -S --noconfirm nodejs npm

echo "Downloading configuration folders from GitHub..."
# List of folders to grab from .config/
CONFIG_FOLDERS=(
    "hypr" "kitty" "alacritty" "dunst" "fastfetch" 
    "mpv" "MangoHud" "nvim" "nwg-look" "pypr" 
    "ranger" "wallpapers" "waybar" "wlogout" "wofi" "rofi"
)

# List of specific files to grab from .config/
CONFIG_FILES=(
    "starship.toml" "chrome-flags.conf"
)

# Loop through folders
for folder in "${CONFIG_FOLDERS[@]}"; do
    echo "Fetching $folder..."
    npx --yes degit owlsly94/dotfiles/.config/$folder ~/.config/$folder --force
done

# Loop through specific files
for file in "${CONFIG_FILES[@]}"; do
    echo "Fetching $file..."
    curl -fLo ~/.config/$file https://raw.githubusercontent.com/owlsly94/dotfiles/main/.config/$file
done

echo "-------------------------------------------------------"
echo "Setup complete! Your Arch system is fully tuned."
echo "Summary:"
echo " - Pacman: Fast & Colorful"
echo " - Mirrors: Rated by speed"
echo " - CPU: Locked to Performance"
echo " - Libvirt: Active & Group assigned"
echo " - SDDM: Autologin to Hyprland enabled"
echo " - Steam: HTTP2 disabled for faster downloads"
echo " - Dotfiles: All dotfiles downloaded and set"
echo ""
echo "Please REBOOT to apply all changes."
