#!/usr/bin/env bash
# Install rojo 7.6.1 (the laptop's version) to ~/bin/rojo so no-Studio runs can build their final place file.
set -e
mkdir -p /home/sarta/bin /home/sarta/rojo_dl
cd /home/sarta/rojo_dl
curl -fsSL -o rojo.zip https://github.com/rojo-rbx/rojo/releases/download/v7.6.1/rojo-7.6.1-linux-x86_64.zip
python3 -c "import zipfile; zipfile.ZipFile('rojo.zip').extractall('.')"
install -m 755 rojo /home/sarta/bin/rojo
/home/sarta/bin/rojo --version
