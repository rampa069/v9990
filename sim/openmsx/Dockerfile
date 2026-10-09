# Headless openMSX with the free C-BIOS ROMs, for sim/openmsx_host.py.
#   docker build -t openmsx-headless .
FROM debian:trixie-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openmsx cbios xvfb xauth libgl1-mesa-dri libglx-mesa0 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
