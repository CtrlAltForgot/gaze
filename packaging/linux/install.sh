#!/usr/bin/env bash
# Install the release archive in this user's account, without root access.
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -x "$source_dir/bundle/gaze" ]]; then
  printf '%s\n' 'Run install.sh from the extracted gaze release archive.' >&2
  exit 1
fi
install_dir="${XDG_DATA_HOME:-$HOME/.local/share}/gaze"
applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$install_dir" "$applications"
if [[ -d "$install_dir/bundle" ]]; then
  mv "$install_dir/bundle" "$install_dir/bundle.previous.$(date +%s)"
fi
cp -a "$source_dir/bundle" "$install_dir/bundle"
# Desktop Exec quoting must escape backslashes, quotes, dollar signs and backticks.
python3 - "$install_dir/bundle/gaze" "$applications/com.example.gaze.desktop" <<'PY'
import sys
from pathlib import Path
exe=sys.argv[1]
quoted='"'+exe.replace('\\','\\\\').replace('"','\\"').replace('`','\\`').replace('$','\\$').replace('%','%%')+'"'
Path(sys.argv[2]).write_text('[Desktop Entry]\nType=Application\nName=gaze\nComment=Your music, brought forward\nExec='+quoted+' %u\nIcon=audio-player\nTerminal=false\nCategories=AudioVideo;Audio;Player;\nMimeType=x-scheme-handler/gaze;\nStartupWMClass=com.example.gaze\n')
PY
if command -v update-desktop-database >/dev/null; then update-desktop-database "$applications"; fi
xdg-mime default com.example.gaze.desktop x-scheme-handler/gaze
printf '%s\n' 'gaze is installed. Open it from your applications menu, or open a Party Session invite.'
