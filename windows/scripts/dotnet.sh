#!/bin/bash
# Runs the .NET SDK the Windows build uses: ~/.dotnet (installed by dotnet-install.sh, no sudo)
# or one on PATH. Downloads skip the proxy: NuGet and Microsoft's CDN are fast direct and very
# slow through it.
export DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
dotnet="$DOTNET_ROOT/dotnet"; [ -x "$dotnet" ] || dotnet=$(command -v dotnet) || { echo "no .NET SDK: run scripts/install-dotnet.sh" >&2; exit 2; }
exec env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY "$dotnet" "$@"
