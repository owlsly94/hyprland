#!/bin/bash
set -e  # Exit on error

# Logging
LOG_FILE="$HOME/arch-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Trap errors
trap 'echo "Error occurred at line $LINENO. Check $LOG_FILE for details."; exit 1' ERR

# Check if running as root
if [ "$EEID" -eq 0 ]; then 
    echo "Don't run this script as root (it uses sudo internally)"
    exit 1
fi

# Verify we're on Arch
command -v pacman >/dev/null 2>&1 || { echo "pacman not found. Is this Arch Linux?"; exit 1; }

# 1. Configure pacman.conf (Misc Options & Multilib)
echo "Beautifying pacman.conf..."
sudo cp /etc/pacman.conf /etc/pacman.conf.backup
sudo sed -i 's/^#Color/Color\nILoveCandy/' /etc/pacman.conf
sudo sed -i 's/^#CheckSpace/CheckSpace/' /etc/pacman.conf
sudo sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
sudo sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf

# Enable Multilib
sudo sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf

# 2. Add Chaotic-AUR
echo "Configuring Chaotic-AUR..."
if ! timeout 30 sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com; then
    echo "Primary keyserver failed, trying alternative..."
    sudo pacman-key --recv-key 3056513887B78AEB --keyserver keys.openpgp.org
fi
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
sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
rate-mirrors --protocol https arch --max-delay 3600 | sudo tee /etc/pacman.d/mirrorlist

# 4. Optimize makepkg for faster AUR builds
echo "Optimizing makepkg for faster compilation..."
sudo cp /etc/makepkg.conf /etc/makepkg.conf.backup
sudo sed -i "s/^#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$(nproc)\"/" /etc/makepkg.conf
sudo sed -i 's/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -z - --threads=0)/' /etc/makepkg.conf
sudo sed -i 's/COMPRESSZST=(zstd -c -z -q -)/COMPRESSZST=(zstd -c -z -q - --threads=0)/' /etc/makepkg.conf

# 5. Sync and Install Yay + Apps
echo "Installing yay and resolving conflicts..."
sudo pacman -Sy --noconfirm --ask 4 yay  # --ask 4 auto-replaces conflicting packages

if [ -f "apps.txt" ]; then
    echo "Installing apps from apps.txt..."
    yay -S --noconfirm --ask 4 --needed - < apps.txt
else
    echo "apps.txt not found, skipping app installation."
fi

# 6. I/O Scheduler Optimization for NVMe/SSD
echo "Optimizing I/O scheduler for SSDs..."
sudo tee /etc/udev/rules.d/60-ioschedulers.rules <<EOF
# Set scheduler for NVMe
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
# Set scheduler for SSD and eMMC
ACTION=="add|change", KERNEL=="sd[a-z]|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# Set scheduler for rotating disks
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF
sudo udevadm control --reload-rules

# 7. Swappiness Tuning
echo "Tuning swappiness for desktop use..."
echo "vm.swappiness=10" | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl -p /etc/sysctl.d/99-swappiness.conf

# 8. CPU Governor Rules & Service
echo "Setting up CPU Performance Governor..."

# Check if performance governor is available
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]; then
    if grep -q "performance" /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors; then
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
        echo "CPU governor set to performance"
    else
        echo "Warning: Performance governor not available on this system"
    fi
else
    echo "Warning: CPU frequency scaling not available (VM or unsupported CPU?)"
fi

# 9. Enable TRIM for SSD longevity
echo "Enabling weekly TRIM for SSD..."
sudo systemctl enable --now fstrim.timer

# 10. Paccache Cleanup Hook
echo "Setting up automatic pacman cache cleanup..."
sudo mkdir -p /etc/pacman.d/hooks
sudo tee /etc/pacman.d/hooks/clean-cache.hook <<EOF
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Package
Target = *

[Action]
Description = Cleaning pacman cache...
When = PostTransaction
Exec = /usr/bin/paccache -rk2
EOF

# 11. Rate-mirrors Monthly Timer
echo "Setting up monthly mirror rating..."
sudo tee /etc/systemd/system/rate-mirrors.service <<EOF
[Unit]
Description=Update mirrorlist with rate-mirrors
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/rate-mirrors --protocol https arch --max-delay 3600 --save /etc/pacman.d/mirrorlist
EOF

sudo tee /etc/systemd/system/rate-mirrors.timer <<EOF
[Unit]
Description=Update mirrorlist monthly

[Timer]
OnCalendar=monthly
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl enable rate-mirrors.timer

# 12. Zram Setup (compressed RAM swap)
echo "Setting up zram..."
sudo pacman -S --noconfirm zram-generator
sudo tee /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF

# 13. Earlyoom (prevents system freeze from OOM)
echo "Installing and enabling earlyoom..."
sudo pacman -S --noconfirm earlyoom
sudo systemctl enable --now earlyoom

# 14. Improve Font Rendering
echo "Improving font rendering for LCD monitors..."
sudo mkdir -p /etc/fonts/conf.d
sudo ln -sf /usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d/
sudo ln -sf /usr/share/fontconfig/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d/

# 15. Libvirt Configuration
echo "Configuring Libvirt..."
sudo cp /etc/libvirt/libvirtd.conf /etc/libvirt/libvirtd.conf.backup
sudo sed -i 's/^#unix_sock_group = "libvirt"/unix_sock_group = "libvirt"/' /etc/libvirt/libvirtd.conf
sudo sed -i 's/^#unix_sock_rw_perms = "0770"/unix_sock_rw_perms = "0770"/' /etc/libvirt/libvirtd.conf

sudo systemctl enable --now libvirtd.service
sudo usermod -a -G libvirt $USER

# 16. SDDM Autologin Configuration
echo "Configuring SDDM Autologin for $USER..."
if [ -f /etc/sddm.conf ]; then
    sudo cp /etc/sddm.conf /etc/sddm.conf.backup
fi

sudo tee /etc/sddm.conf <<EOF
[Autologin]
User=$USER
Session=hyprland
EOF

# 17. Steam Download Optimization (steam_dev.cfg)
echo "Applying Steam download optimizations..."
mkdir -p "$HOME/.steam/steam/"
cat <<EOF > "$HOME/.steam/steam/steam_dev.cfg"
@nClientDownloadEnableHTTP2PlatformLinux 0
@fDownloadRateImprovementToAddAnotherConnection 1.0
EOF

# 18. Download Dotfiles using npx degit
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

# Backup existing configs if they exist
for folder in "${CONFIG_FOLDERS[@]}"; do
    if [ -d "$HOME/.config/$folder" ]; then
        mv "$HOME/.config/$folder" "$HOME/.config/${folder}.backup"
        echo "Backed up existing $folder to ${folder}.backup"
    fi
done

# Loop through folders
for folder in "${CONFIG_FOLDERS[@]}"; do
    echo "Fetching $folder..."
    if ! npx --yes degit owlsly94/dotfiles/.config/$folder ~/.config/$folder --force; then
        echo "Warning: Failed to fetch $folder, skipping..."
    fi
done

# Loop through specific files
for file in "${CONFIG_FILES[@]}"; do
    echo "Fetching $file..."
    if ! curl -fLo ~/.config/$file --create-dirs https://raw.githubusercontent.com/owlsly94/dotfiles/main/.config/$file; then
        echo "Warning: Failed to fetch $file, skipping..."
    fi
done

# 19. Fetch .zshrc to home directory
echo "Fetching .zshrc..."
if [ -f "$HOME/.zshrc" ]; then
    mv "$HOME/.zshrc" "$HOME/.zshrc.backup"
    echo "Backed up existing .zshrc to .zshrc.backup"
fi

if ! curl -fLo ~/.zshrc https://raw.githubusercontent.com/owlsly94/dotfiles/refs/heads/main/.zshrc; then
    echo "Warning: Failed to fetch .zshrc, skipping..."
fi

# 20. Fetch and extract zsh.tar.gz to ~/.config
echo "Fetching and extracting zsh configuration archive..."
if ! curl -fLo /tmp/zsh.tar.gz https://github.com/owlsly94/dotfiles/raw/refs/heads/main/.config/zsh.tar.gz; then
    echo "Warning: Failed to fetch zsh.tar.gz, skipping..."
else
    # Backup existing zsh folder if it exists
    if [ -d "$HOME/.config/zsh" ]; then
        mv "$HOME/.config/zsh" "$HOME/.config/zsh.backup"
        echo "Backed up existing zsh folder to zsh.backup"
    fi
    
    # Extract to ~/.config
    tar -xzf /tmp/zsh.tar.gz -C ~/.config/
    rm /tmp/zsh.tar.gz
    echo "zsh configuration extracted successfully"
fi

# 21. Generate installed packages list
echo "Generating installed packages list..."
pacman -Qqe > ~/installed-packages.txt

echo "-------------------------------------------------------"
echo "Setup complete! Your Arch system is fully tuned."
echo "Summary:"
echo " - Pacman: Fast & Colorful with auto-cleanup"
echo " - Mirrors: Rated by speed (auto-updates monthly)"
echo " - Makepkg: Optimized for $(nproc) cores"
echo " - I/O Scheduler: Optimized for NVMe/SSD"
echo " - Swappiness: Set to 10 for desktop responsiveness"
echo " - CPU: Locked to Performance"
echo " - TRIM: Enabled weekly for SSD health"
echo " - Zram: Configured for compressed swap"
echo " - Earlyoom: Prevents system freeze from memory issues"
echo " - Font Rendering: Subpixel RGB + LCD filtering enabled"
echo " - Libvirt: Active & Group assigned"
echo " - SDDM: Autologin to Hyprland enabled"
echo " - Steam: HTTP2 disabled for faster downloads"
echo " - Dotfiles: All dotfiles downloaded and set"
echo " - Zsh: .zshrc and zsh config deployed"
echo ""
echo "Log saved to: $LOG_FILE"
echo "Backups created with .backup extension"
echo "Installed packages list: ~/installed-packages.txt"
echo ""
echo "Please REBOOT to apply all changes."
