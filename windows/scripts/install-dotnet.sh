#!/bin/bash
# Installs the .NET 10 SDK into ~/.dotnet with Microsoft's script (no sudo, nothing system-wide).
set -euo pipefail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$T/dotnet-install.sh"
env -u http_proxy -u https_proxy -u all_proxy bash "$T/dotnet-install.sh" --channel 10.0 --install-dir "$HOME/.dotnet"
