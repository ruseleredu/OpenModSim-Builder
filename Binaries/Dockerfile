# ============================================================================
# Windows x64 cross-build environment for OpenModSim, using PREBUILT Qt.
#
# Nothing is compiled here. The image contains:
#   - Ubuntu's MinGW-w64 cross-compiler (GCC 13, posix threads, SEH)
#   - the official Qt MinGW binaries for Windows (the libraries we link against)
#   - the official Qt binaries for Linux, same version (moc/uic/rcc/lupdate/
#     qhelpgenerator run on the build machine; Qt calls this QT_HOST_PATH)
# all downloaded with aqtinstall. build.sh then runs INSIDE the container.
#
#   docker build -t omodsim-win .
#   docker run --rm -v "$PWD/dist:/build/dist" omodsim-win
# ============================================================================
FROM ubuntu:24.04

# Qt 6.8+ official MinGW builds use MinGW 13.1, which is ABI-compatible with
# Ubuntu 24.04's GCC 13.2 cross-compiler. Qlementine needs Qt >= 6.8.
ARG QT_VERSION=6.8.3
ARG QT_MODULES="qtserialport qtserialbus qt5compat"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC

# apt-install: apt-get update + install, retried up to 3 times. Ubuntu's
# mirrors are sometimes briefly out of sync while a security update is
# published (404 on a .deb the index already lists); a fresh update fixes it.
RUN printf '%s\n' \
        '#!/bin/sh' \
        'for i in 1 2 3; do' \
        '  if apt-get update && apt-get install -y --no-install-recommends -o Acquire::Retries=3 "$@"; then' \
        '    rm -rf /var/lib/apt/lists/*; exit 0' \
        '  fi' \
        '  echo "apt-install: attempt $i failed, retrying in 30s..." >&2; sleep 30' \
        'done' \
        'exit 1' \
        > /usr/local/bin/apt-install \
    && chmod +x /usr/local/bin/apt-install

# ---------------------------------------------------------------------------
# 1. Cross-compiler, build tools, packaging tools, and the shared libraries
#    the Linux (host) Qt tools need to run (qhelpgenerator links QtGui).
#    qt6-documentation-tools is only a fallback qhelpgenerator.
# ---------------------------------------------------------------------------
RUN apt-install \
        gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix \
        binutils-mingw-w64-x86-64 mingw-w64-x86-64-dev \
        ninja-build git ca-certificates python3 python3-venv \
        nsis zip p7zip-full \
        libglib2.0-0t64 libgl1 libegl1 libopengl0 libfontconfig1 \
        libfreetype6 libxkbcommon0 libdbus-1-3 \
        qt6-documentation-tools

# ---------------------------------------------------------------------------
# 2. aqtinstall + a CMake new enough for OpenModSim (needs >= 3.28.4;
#    Ubuntu 24.04 ships 3.28.3). Kept below 4.0 for FetchContent deps.
# ---------------------------------------------------------------------------
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir aqtinstall "cmake>=3.28.4,<4"
ENV PATH=/opt/venv/bin:${PATH}

# ---------------------------------------------------------------------------
# 3. Prebuilt Qt: Windows MinGW (target) + Linux (host), same version and
#    modules. Base "essentials" already include qtbase, qtdeclarative, qtsvg,
#    qttools and qttranslations.
#      /opt/qt/<ver>/mingw_64   target Qt  (headers, .a import libs, DLLs)
#      /opt/qt/<ver>/gcc_64     host Qt    (tools that run during the build)
# ---------------------------------------------------------------------------
RUN aqt install-qt linux   desktop "${QT_VERSION}" linux_gcc_64 -O /opt/qt -m ${QT_MODULES} \
    && aqt install-qt windows desktop "${QT_VERSION}" win64_mingw  -O /opt/qt -m ${QT_MODULES} \
    && rm -f aqtinstall.log \
    && test -f "/opt/qt/${QT_VERSION}/mingw_64/lib/cmake/Qt6/Qt6Config.cmake" \
    && test -x "/opt/qt/${QT_VERSION}/gcc_64/libexec/moc"

ENV QT_VERSION=${QT_VERSION} \
    QT_ROOT=/opt/qt

WORKDIR /build
COPY build.sh /build/scripts/build.sh
RUN chmod +x /build/scripts/build.sh

CMD ["/build/scripts/build.sh"]
