#!/bin/bash
# Run the phone server outside the app, against a throwaway tmux server.
#
#   tmux -L demo new-session -d -s acme-app -n checkout-fix
#   scripts/mobile-dev-server.sh --socket demo --port 7433 \
#       --static app/MuxMaestro/Resources/mobile
#   curl -H 'Host: devmac.example.ts.net' -H 'Tailscale-User-Login: me@example.com' \
#       http://127.0.0.1:7433/api/threads
#
# It compiles the same Foundation-only sources the test target does, plus
# scripts/mobile-dev-server/main.swift. It never reads the real tmux server.
set -euo pipefail
cd "$(dirname "$0")/.."

out="${TMPDIR:-/tmp}/muxmaestro-mobile-dev-server"
# Every app source the test target compiles (they need no AppKit).
sources=$(sed -n '/A0000034 \/\* Sources \*\//,/runOnlyForDeploymentPostprocessing/p' \
    MuxMaestro.xcodeproj/project.pbxproj \
  | grep -oE '[A-Za-z0-9+]+\.swift in Sources' | sed 's/ in Sources//' \
  | grep -v 'Tests\.swift$' | sort -u | sed 's|^|app/MuxMaestro/|')

newest=$(ls -t $sources scripts/mobile-dev-server/main.swift | head -1)
if [ ! -x "$out" ] || [ "$newest" -nt "$out" ]; then
  # shellcheck disable=SC2086
  xcrun swiftc -O -o "$out" $sources scripts/mobile-dev-server/main.swift
fi
exec "$out" "$@"
