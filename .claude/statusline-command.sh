#!/usr/bin/env bash
set -euo pipefail

config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
exec python3 "$config_home/ai-statusline/statusline.py" render claude
