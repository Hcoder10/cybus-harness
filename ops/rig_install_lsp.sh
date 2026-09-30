#!/usr/bin/env bash
# Install luau-lsp 1.70.1 and Roblox's game-script definitions to ~/bin for the harness's API check.
set -e
mkdir -p /home/sarta/bin/luau-lsp-defs /home/sarta/lsp_dl
cd /home/sarta/lsp_dl
curl -fsSL -o lsp.zip https://github.com/JohnnyMorganz/luau-lsp/releases/download/1.70.1/luau-lsp-linux-x86_64.zip
python3 -c "import zipfile; zipfile.ZipFile('lsp.zip').extractall('.')"
install -m 755 luau-lsp /home/sarta/bin/luau-lsp
curl -fsSL -o /home/sarta/bin/luau-lsp-defs/globalTypes.None.d.luau \
  https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.None.d.luau
/home/sarta/bin/luau-lsp --version
wc -c /home/sarta/bin/luau-lsp-defs/globalTypes.None.d.luau
