#!/bin/zsh
# Builds Ports.app and installs it to ~/Applications.
set -euo pipefail
exec "$(dirname "$0")/Scripts/build_app.sh"
