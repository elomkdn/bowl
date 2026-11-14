#!/usr/bin/env bash
#
# install.sh — installs or updates the Bowl widget for your user
#
# Usage:
#   ./install.sh               install, or update in place
#   ./install.sh --uninstall   remove it
#
# Then add it to a panel (right-click the panel, Add Widgets, Bowl). After an update,
# log out and back in, or run: systemctl --user restart plasma-plasmashell

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ID="com.github.elomkdn.bowl"
# Its icon in the widget list, from the icon theme
ICON="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/$ID.svg"

if [[ "${1:-}" == "--uninstall" || "${1:-}" == "-u" ]]; then
  kpackagetool6 -t Plasma/Applet -r "$ID"
  rm -f "$ICON"
  exit 0
fi

# the French catalog, from po/fr.po
if command -v msgfmt >/dev/null; then
  mkdir -p package/contents/locale/fr/LC_MESSAGES
  msgfmt -o "package/contents/locale/fr/LC_MESSAGES/plasma_applet_$ID.mo" po/fr.po
fi

install -Dm644 "package/contents/icons/$ID.svg" "$ICON"

if kpackagetool6 -t Plasma/Applet -s "$ID" >/dev/null 2>&1; then
  kpackagetool6 -t Plasma/Applet -u package
else
  kpackagetool6 -t Plasma/Applet -i package
fi
