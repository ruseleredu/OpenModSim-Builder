# ============================================================================
# Windows x64 cross-build environment for OpenModSim (MXE + Qt 6).
#
# The slow part -- cross-building Qt 6 and its dependencies with MXE -- runs
# once, here, and is cached in the image (expect several hours and ~15 GB of
# disk during the build). build.sh then runs INSIDE the container and takes
# only minutes.
#
#   docker build -t omodsim-mxe .
#   docker run --rm -v "$PWD/dist:/build/dist" omodsim-mxe
#
# Build on an x86_64 (amd64) host: MXE needs g++-multilib / libc6-dev-i386.
# ============================================================================
FROM ubuntu:24.04

ARG MXE_REF=master
ARG MXE_TARGET=x86_64-w64-mingw32.shared
# Optional newer GCC, e.g. --build-arg MXE_PLUGIN_DIRS=plugins/gcc14
ARG MXE_PLUGIN_DIRS=
# Parallel jobs per package (default: all cores)
ARG JOBS=

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
# 1. MXE host requirements (see mxe/docs/index.html#requirements-debian),
#    plus python3-yaml, which Mesa 26 needs (not in MXE's list yet).
# ---------------------------------------------------------------------------
RUN apt-install \
        autoconf automake autopoint bash bison bzip2 ca-certificates flex \
        g++ g++-multilib gettext git gperf intltool libc6-dev-i386 \
        libclang-dev libgdk-pixbuf-2.0-dev libltdl-dev libgl-dev \
        libpcre2-dev libssl-dev libtool-bin libxml-parser-perl lzip make \
        openssl p7zip-full patch perl python3 python3-mako \
        python3-packaging python3-pkg-resources python3-setuptools \
        python3-yaml \
        python-is-python3 ruby sed sqlite3 unzip wget xz-utils \
    && python3 -c "import yaml, mako, packaging; print('python deps OK')"

# ---------------------------------------------------------------------------
# 2. Extra tools used by build.sh:
#    qt6-documentation-tools : native qhelpgenerator. MXE's host Qt is built
#                              without the SQLite driver, so its own
#                              qhelpgenerator can't write .qch/.qhc files.
#    nsis                    : makensis, for the optional installer.
#    zip                     : packaging.
# ---------------------------------------------------------------------------
RUN apt-install \
        qt6-documentation-tools nsis zip


# ---------------------------------------------------------------------------
# 3. Cross-build Qt 6 with MXE, in several layers. Docker caches every
#    finished layer, so if a later step fails, a rebuild resumes from the
#    last good one instead of starting the whole multi-hour build again.
#    mxe-make wraps MXE's make with the target/jobs/plugin settings and drops
#    the downloaded source tarballs afterwards to keep each layer small.
# ---------------------------------------------------------------------------
RUN git clone https://github.com/mxe/mxe.git /opt/mxe \
    && git -C /opt/mxe checkout "${MXE_REF}" \
    && printf '%s\n' \
        '#!/bin/sh' \
        'set -e' \
        'cd /opt/mxe' \
        "make --jobs=2 JOBS=\"\${JOBS:-\$(nproc)}\" MXE_TARGETS=\"${MXE_TARGET}\" ${MXE_PLUGIN_DIRS:+MXE_PLUGIN_DIRS=\"${MXE_PLUGIN_DIRS}\"} \"\$@\"" \
        'rm -rf /opt/mxe/pkg/*' \
        > /usr/local/bin/mxe-make \
    && chmod +x /usr/local/bin/mxe-make \
    && cat /usr/local/bin/mxe-make

# 3a. Cross-compiler (GCC, binutils, MinGW-w64), CMake, Meson, Ninja.
RUN mxe-make cc cmake meson-wrapper

# 3b. Qt's third-party dependencies (Mesa, ICU, OpenSSL, ...).
RUN mxe-make mesa icu4c openssl dbus freetype harfbuzz jpeg libpng \
             mariadb-connector-c pcre2 sqlite zlib zstd

# 3c. Qt base (host tools + Windows target).
RUN mxe-make qt6-qtbase

# 3d. The other Qt modules OpenModSim links against, plus translations.
RUN mxe-make qt6-qtdeclarative qt6-qttools qt6-qtserialport \
             qt6-qtserialbus qt6-qt5compat qt6-qtsvg qt6-qttranslations \
    && make -C /opt/mxe clean-junk \
    && rm -rf /opt/mxe/.ccache

ENV MXE=/opt/mxe \
    MXE_TARGET=${MXE_TARGET} \
    PATH=/opt/mxe/usr/bin:${PATH}

WORKDIR /build
COPY build.sh /build/scripts/build.sh
RUN chmod +x /build/scripts/build.sh

CMD ["/build/scripts/build.sh"]
