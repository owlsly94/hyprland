#!/bin/bash

LIST="apps.txt"

if [ ! -f "$LIST" ]; then
    echo "Error: File named $LIST is not there!"
    exit 1
fi

if ! command -v yay &> /dev/null; then
    echo "--- yay not found... Installing yay... ---"
    
    sudo pacman -S --needed base-devel git --noconfirm
    
    TEMP_DIR=$(mktemp -d)
    git clone https://aur.archlinux.org/yay.git "$TEMP_DIR/yay"
    
    cd "$TEMP_DIR/yay" || exit
    makepkg -si --noconfirm
    
    cd ~ || exit
    rm -rf "$TEMP_DIR"
    echo "--- yay successfully installed... ---"
else
    echo "--- yay is installed... Continuing... ---"
fi

echo "--- Installing apps from the list... ---"
yay -S --needed --noconfirm - < "$LIST"

echo "--- Finished! All apps from the list are installed... ---"
