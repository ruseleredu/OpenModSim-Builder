# syntax=docker/dockerfile:1
#
# OpenModSim (Modbus slave/server simulator) in a browser, on LinuxServer's
# Selkies base image (Debian Trixie).
#
#   docker build -t openmodsim-selkies .
#   docker run -d --name openmodsim --shm-size=1gb \
#     -p 3001:3001 -p 502:502 -v ./config:/config openmodsim-selkies
#   -> https://localhost:3001
#
# Both stages use Debian Trixie so the compiled binary matches the runtime libs.

ARG SELKIES_TAG=debiantrixie
ARG OMODSIM_REF=2.0.1

############################
# Stage 1: build
############################
FROM debian:trixie AS builder
ARG OMODSIM_REF

ENV DEBIAN_FRONTEND=noninteractive

# Build dependencies (Qt6 package set taken from upstream build.sh for Debian).
# Trixie ships CMake 3.31, which meets the 3.28.4 minimum.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build git ca-certificates pkg-config \
      libxcb-cursor-dev libgl1-mesa-dev libcups2-dev \
      qt6-base-dev qt6-base-dev-tools qt6-declarative-dev \
      qt6-tools-dev qt6-tools-dev-tools qt6-l10n-tools \
      qt6-serialport-dev qt6-serialbus-dev qt6-5compat-dev \
      qt6-documentation-tools libqt6svg6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${OMODSIM_REF}" \
      https://github.com/sanny32/OpenModSim.git /src

RUN cmake -S /src/src -B /build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DUSE_QT6=ON \
      -DOMODSIM_BUILD_TESTS=OFF \
    && ninja -C /build \
    && DESTDIR=/out ninja -C /build install

# Work out which Debian packages provide the libraries the binary links to,
# so the runtime stage installs exactly those (no hard-coded t64 names).
RUN ldd /out/usr/bin/omodsim2 | awk '/=>/ {print $3}' \
    | xargs -r readlink -f \
    | xargs -r dpkg -S 2>/dev/null \
    | cut -d: -f1 | sort -u > /out/runtime-packages.txt \
    && cat /out/runtime-packages.txt

############################
# Stage 2: runtime
############################
FROM ghcr.io/linuxserver/baseimage-selkies:${SELKIES_TAG}

LABEL org.opencontainers.image.title="OpenModSim (Selkies)" \
      org.opencontainers.image.description="Open ModSim Modbus slave utility served in the browser via Selkies" \
      org.opencontainers.image.source="https://github.com/sanny32/OpenModSim"

ENV TITLE="Open ModSim"

COPY --from=builder /out/runtime-packages.txt /tmp/runtime-packages.txt

# Runtime libs detected above + Qt plugins that are loaded dynamically
# (not visible to ldd): xcb/wayland platform, sqlite driver for the
# script help (.qhc), SVG icon/image plugins.
RUN apt-get update \
    && xargs -a /tmp/runtime-packages.txt apt-get install -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
         qt6-qpa-plugins qt6-wayland libqt6sql6-sqlite libqt6svg6 \
         qt6-image-formats-plugins libcap2-bin socat \
    && rm -rf /var/lib/apt/lists/* /tmp/runtime-packages.txt

COPY --from=builder /out/usr/ /usr/

# Let the app bind the standard Modbus TCP port 502 as the non-root abc user
# (same thing upstream's `ninja install` does when setcap is available).
RUN setcap cap_net_bind_service=+ep /usr/bin/omodsim2 \
    && (update-mime-database /usr/share/mime >/dev/null 2>&1 || true)

# Autostart, right-click menu, and the optional serial-over-TCP bridge service
COPY root/ /
# chmod here because building from Windows can drop the executable bit;
# sed strips CRLF in case the file was saved with Windows line endings
RUN sed -i 's/\r$//' /etc/s6-overlay/s6-rc.d/svc-serialbridge/run \
    && chmod +x /etc/s6-overlay/s6-rc.d/svc-serialbridge/run

# 3000 = HTTP, 3001 = HTTPS (Selkies web UI), 502 = Modbus TCP
EXPOSE 3000 3001 502
VOLUME /config
