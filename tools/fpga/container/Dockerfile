# Quartus Prime Lite (x86-64 Linux) を Apple container + Rosetta 2 で走らせる土台。
# Quartus そのものは入れない (volume quartus の /opt/quartus に入れる)。ここは Quartus が要る共有ライブラリと locale だけ。
#   container build --arch amd64 -t r2p2-quartus tools/fpga/container
FROM ubuntu:22.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      locales libglib2.0-0 libbz2-1.0 libcrypt1 libnsl2 libfontconfig1 libx11-xcb1 libxext6 libsm6 \
      libdbus-1-3 libxft2 libxtst6 libxi6 libxrender1 libtcmalloc-minimal4 ca-certificates \
    && locale-gen en_US.UTF-8 && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8
