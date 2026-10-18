#!/bin/sh
# Quartus Prime Lite を volume quartus (/opt/quartus) に入れる。
# 引数はインストーラと .qdz を置いた dir (Alteraの配布はログインが要るので、人が落として置く)。
#   tools/fpga/container/install.sh build/quartus-installer
# 先に image を作っておく: container build --arch amd64 -t r2p2-quartus tools/fpga/container
set -e
inst=$(cd "${1:?installer dir}" && pwd)
run=$(cd "$inst" && ls QuartusLiteSetup-*-linux.run)
container run --rm --arch amd64 --rosetta -m 8G -c 4 \
  -v quartus:/opt/quartus -v "$inst":/inst \
  "${FPGA_QUARTUS_IMAGE:-r2p2-quartus}" \
  sh -c "chmod +x /inst/$run && /inst/$run --mode unattended --accept_eula 1 --installdir /opt/quartus && du -sh /opt/quartus"
