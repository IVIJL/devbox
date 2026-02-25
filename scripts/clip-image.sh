#!/bin/bash
set -euo pipefail

CLIP_DIR="${HOME}/.clipboard-images"
mkdir -p "$CLIP_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FILENAME="clip-${TIMESTAMP}.png"
HOST_PATH="${CLIP_DIR}/${FILENAME}"

# Convert WSL path to Windows path for PowerShell
WIN_PATH=$(wslpath -w "$HOST_PATH")

# Grab image from Windows clipboard via PowerShell
# Uses Windows PowerShell 5.1 (not pwsh) which has System.Drawing available
if ! powershell.exe -NoProfile -Command "
Add-Type -AssemblyName System.Windows.Forms
\$img = [System.Windows.Forms.Clipboard]::GetImage()
if (\$img -eq \$null) {
    Write-Error 'No image in clipboard'
    exit 1
}
\$img.Save('${WIN_PATH}')
" 2>/dev/null; then
    echo "ERROR: No image found in clipboard" >&2
    exit 1
fi

if [ ! -f "$HOST_PATH" ]; then
    echo "ERROR: Failed to save clipboard image" >&2
    exit 1
fi

# Clean up images older than 24 hours
find "$CLIP_DIR" -name 'clip-*.png' -mmin +1440 -delete 2>/dev/null || true

# Use ~/.clipboard-images/ path (works on both host and inside container)
echo "${HOME}/.clipboard-images/${FILENAME}"
