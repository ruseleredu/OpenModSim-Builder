#!/usr/bin/env bash
# ============================================================================
# Checkout OpenModSim, cross-build it for Windows x64, and package a dist.
# Runs INSIDE the container built from the Dockerfile. Everything here is fast
# relative to the image build (Qt 6 is already cross-built and cached by MXE).
#
# Environment knobs:
#   OMODSIM_REF=main        branch/tag to clone (ignored if the source dir is
#                           already present, e.g. a mounted local checkout)
#   QLEMENTINE=0|1          experimental Qlementine app style (MXE Qt is 6.11)
#   LTO=1|0                 link-time optimization (upstream turns it on)
#   BUILD_TYPE=Release
#   MAKE_INSTALLER=0|1      also build an NSIS setup .exe with makensis
#   QHELPGENERATOR=<path>   override the native qhelpgenerator
#   JOBS=<n>                parallel compile jobs (default: all cores)
# ============================================================================
set -euo pipefail

: "${MXE:=/opt/mxe}"
: "${MXE_TARGET:=x86_64-w64-mingw32.shared}"
: "${OMODSIM_REPO:=https://github.com/sanny32/OpenModSim.git}"
: "${OMODSIM_REF:=main}"
: "${QLEMENTINE:=0}"
: "${LTO:=1}"
: "${BUILD_TYPE:=Release}"
: "${MAKE_INSTALLER:=0}"
JOBS="${JOBS:-$(nproc)}"

SRC=/build/src
DIST=/build/dist
APP="${SRC}/OpenModSim"
BUILD="${SRC}/build-omodsim-windows-x64"
OUT="${SRC}/OpenModSim-windows-x64"

PREFIX="${MXE}/usr/${MXE_TARGET}"          # MXE install prefix for this target
QT6="${PREFIX}/qt6"                        # cross-built (target) Qt 6
BIN="${PREFIX}/bin"                        # MinGW runtime + third-party DLLs
OBJDUMP="${MXE_TARGET}-objdump"

# MXE keeps its host tools (cmake, ninja, host Qt 6) under usr/<build-triplet>.
HOST_TRIPLET=""
for d in "${MXE}"/usr/*-linux-gnu*; do
  if [ -d "${d}" ]; then HOST_TRIPLET="$(basename "${d}")"; break; fi
done
HOST_PREFIX="${MXE}/usr/${HOST_TRIPLET}"
QT_HOST="${HOST_PREFIX}/qt6"
HOST_CMAKE="${HOST_PREFIX}/bin/cmake"      # MXE's cmake (>= 3.28.4 required)

export PATH="${MXE}/usr/bin:${HOST_PREFIX}/bin:${PATH}"
export GIT_TERMINAL_PROMPT=0   # never hang on a username/password prompt
export QT_QPA_PLATFORM=offscreen   # native Qt tools (qhelpgenerator) run headless

# ---------------------------------------------------------------------------
# 0. Sanity checks.
# ---------------------------------------------------------------------------
die() { echo "!! $*" >&2; exit 1; }

[ -n "${HOST_TRIPLET}" ]                         || die "MXE host prefix not found under ${MXE}/usr"
[ -f "${QT6}/lib/cmake/Qt6/Qt6Config.cmake" ]    || die "Target Qt 6 not found at ${QT6}"
[ -d "${QT_HOST}" ]                              || die "Host Qt 6 not found at ${QT_HOST}"
[ -x "${HOST_CMAKE}" ]                           || die "MXE cmake not found at ${HOST_CMAKE}"
command -v "${OBJDUMP}" >/dev/null 2>&1          || die "${OBJDUMP} not found in PATH"

# qhelpgenerator runs at BUILD time, so it must be a native Linux binary.
# MXE's host Qt has no SQLite driver, so use the distro's (qt6-documentation-tools).
if [ -z "${QHELPGENERATOR:-}" ]; then
  for c in /usr/lib/qt6/libexec/qhelpgenerator /usr/lib/qt6/bin/qhelpgenerator \
           "$(command -v qhelpgenerator 2>/dev/null || true)"; do
    [ -n "${c}" ] && [ -x "${c}" ] && { QHELPGENERATOR="${c}"; break; }
  done
fi
[ -n "${QHELPGENERATOR:-}" ] || die "qhelpgenerator not found (apt install qt6-documentation-tools)"

# Configure through MXE's own cmake wrapper: it loads MXE's toolchain file,
# which sets the cross-compiler to ${MXE}/usr/bin/${MXE_TARGET}-g++ and
# QT_HOST_PATH. (Qt's qt-cmake wrapper resolves the compiler into the host
# tools dir, usr/<host-triplet>/bin, where it doesn't exist.)
TARGET_CXX="${MXE}/usr/bin/${MXE_TARGET}-g++"
[ -x "${TARGET_CXX}" ]                           || die "MXE cross-compiler not found at ${TARGET_CXX}"
command -v "${MXE_TARGET}-cmake" >/dev/null 2>&1 || die "${MXE_TARGET}-cmake not found in PATH"
CONFIGURE=("${MXE_TARGET}-cmake"
           "-DCMAKE_PREFIX_PATH=${QT6};${PREFIX}"
           "-DQT_HOST_PATH=${QT_HOST}")

echo "==> MXE target:     ${MXE_TARGET}"
echo "==> Compiler:       ${TARGET_CXX}"
echo "==> Qt (target):    ${QT6}"
echo "==> Qt (host):      ${QT_HOST}"
echo "==> cmake:          ${HOST_CMAKE} ($("${HOST_CMAKE}" --version | head -n1))"
echo "==> qhelpgenerator: ${QHELPGENERATOR}"
mkdir -p "${SRC}" "${DIST}"
cd "${SRC}"

# ---------------------------------------------------------------------------
# 1. Fetch OpenModSim. An existing checkout is reused as-is, so you can mount
#    your own working copy at ${APP} and rebuild it after editing.
# ---------------------------------------------------------------------------
if [ ! -d "${APP}/.git" ] && [ ! -f "${APP}/src/CMakeLists.txt" ]; then
  echo "==> Cloning OpenModSim (${OMODSIM_REF})"
  git clone --depth 1 --branch "${OMODSIM_REF}" "${OMODSIM_REPO}" "${APP}"
else
  echo "==> Reusing existing source at ${APP}"
fi
# A mounted checkout is owned by another uid; let git (version suffix) read it.
git config --global --add safe.directory "${APP}" 2>/dev/null || true

APP_VERSION="$(grep -m1 -oP '^\s*VERSION\s+\K[0-9]+\.[0-9]+\.[0-9]+' "${APP}/src/CMakeLists.txt")"
echo "==> OpenModSim version: ${APP_VERSION}"

# ---------------------------------------------------------------------------
# 2. Configure.
#    - USE_QT6=ON                  MXE provides Qt 6 only.
#    - OMODSIM_BUILD_TESTS=OFF     test executables can't run on the Linux host.
#    - BUILD_SHARED_LIBS=OFF       MXE's shared toolchain defaults this to ON,
#                                  which would turn FetchContent deps
#                                  (qlementine) into DLLs; keep them static.
#    - QHELP_GENERATOR_EXECUTABLE  native tool, see step 0.
#    - LTO=0 overrides the upstream set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
#      via the per-config variable, which takes precedence.
# ---------------------------------------------------------------------------
echo "==> Configuring"
rm -rf "${BUILD}"
QLEM_OPT=OFF; if [ "${QLEMENTINE}" = "1" ]; then QLEM_OPT=ON; fi

CMAKE_ARGS=(
  -S "${APP}/src" -B "${BUILD}" -G Ninja
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
  -DUSE_QT6=ON
  -DOMODSIM_BUILD_TESTS=OFF
  -DBUILD_SHARED_LIBS=OFF
  -DUSE_QLEMENTINE_APP_STYLE="${QLEM_OPT}"
  -DQHELP_GENERATOR_EXECUTABLE="${QHELPGENERATOR}"
)
if [ "${LTO}" = "0" ]; then
  CMAKE_ARGS+=("-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_${BUILD_TYPE^^}=OFF")
fi
"${CONFIGURE[@]}" "${CMAKE_ARGS[@]}"

# ---------------------------------------------------------------------------
# 3. Build.
# ---------------------------------------------------------------------------
echo "==> Building"
"${HOST_CMAKE}" --build "${BUILD}" -j "${JOBS}"

EXE="$(find "${BUILD}" -maxdepth 2 -iname 'omodsim.exe' | head -n1)"
[ -n "${EXE}" ] || die "omodsim.exe not found -- build failed"
echo "==> Built: ${EXE}"

# ---------------------------------------------------------------------------
# 4. Stage the app with the same layout as the official Windows installer:
#      omodsim.exe, demos/, docs/jshelp.{qch,qhc}, plugins/, translations/
#    (We don't use 'cmake --install': its Windows rules call windeployqt,
#    which doesn't exist for a Linux host. Steps 5-6 do its job instead.)
# ---------------------------------------------------------------------------
echo "==> Staging ${OUT}"
rm -rf "${OUT}"; mkdir -p "${OUT}/docs"
cp "${EXE}" "${OUT}/omodsim.exe"
cp -a "${APP}/demos" "${OUT}/demos"
cp "${BUILD}"/docs/jshelp.qch "${BUILD}"/docs/jshelp.qhc "${OUT}/docs/"
if [ -f "${APP}/src/res/license.txt" ]; then cp "${APP}/src/res/license.txt" "${OUT}/"; fi

# ---------------------------------------------------------------------------
# 5. Resolve DLL dependencies recursively with objdump.
# ---------------------------------------------------------------------------
echo "==> Resolving DLL dependencies"
SEARCH_DIRS=("${QT6}/bin" "${BIN}")

find_dll() {  # print full path of first matching DLL across the search dirs
  local name="$1" d
  for d in "${SEARCH_DIRS[@]}"; do
    [ -f "${d}/${name}" ] && { printf '%s\n' "${d}/${name}"; return 0; }
  done
  return 1
}

# Scan every exe/dll in $1 (plus what's already in ${OUT}), copying any missing
# dependency DLL into ${OUT}. Repeat until a full pass copies nothing.
# System DLLs (KERNEL32.dll, ...) aren't in the search dirs and are skipped.
scan_and_resolve() {
  local scandir="$1" copied=1 f dep src
  while [ "${copied}" -gt 0 ]; do
    copied=0
    for f in "${scandir}"/*.exe "${scandir}"/*.dll "${OUT}"/*.dll; do
      [ -e "${f}" ] || continue
      while read -r dep; do
        [ -n "${dep}" ] || continue
        [ -f "${OUT}/${dep}" ] && continue
        if src="$(find_dll "${dep}")"; then
          cp "${src}" "${OUT}/" && { echo "    + ${dep}"; copied=$((copied + 1)); }
        fi
      done < <("${OBJDUMP}" -p "${f}" 2>/dev/null | awk '/DLL Name:/ {print $3}')
    done
  done
  return 0
}
scan_and_resolve "${OUT}"

# ---------------------------------------------------------------------------
# 6. Qt plugins -> plugins/<group>/, the same set the upstream windeployqt
#    step keeps (no gif/jpeg/tiff/..., only the SQLite driver for QtHelp).
#    qt.conf points Qt at plugins/ and translations/ next to the exe.
# ---------------------------------------------------------------------------
echo "==> Copying Qt plugins"
QT_PLUGINS="${QT6}/plugins"
copy_plugins() {  # copy_plugins <group> [dll ...]   (no dll list = whole group)
  local grp="$1"; shift
  [ -d "${QT_PLUGINS}/${grp}" ] || return 0
  mkdir -p "${OUT}/plugins/${grp}"
  if [ $# -eq 0 ]; then
    cp -a "${QT_PLUGINS}/${grp}/." "${OUT}/plugins/${grp}/"
  else
    local p
    for p in "$@"; do
      if [ -f "${QT_PLUGINS}/${grp}/${p}" ]; then
        cp "${QT_PLUGINS}/${grp}/${p}" "${OUT}/plugins/${grp}/"
      fi
    done
  fi
  find "${OUT}/plugins/${grp}" -type f ! -iname '*.dll' -delete   # drop .a/.prl/.debug
  scan_and_resolve "${OUT}/plugins/${grp}"
}
copy_plugins platforms    qwindows.dll
copy_plugins styles
copy_plugins imageformats qsvg.dll qico.dll
copy_plugins iconengines  qsvgicon.dll
copy_plugins sqldrivers   qsqlite.dll

cat > "${OUT}/qt.conf" <<'EOF'
[Paths]
Prefix = .
Plugins = plugins
Translations = translations
EOF

# Qt's own translations for the languages OpenModSim ships (ru, zh_CN, zh_TW).
# The app's own .qm files are compiled into the exe via resources.qrc.
if [ -d "${QT6}/translations" ]; then
  mkdir -p "${OUT}/translations"
  for lang in ru zh_CN zh_TW; do
    for mod in qt qtbase qtserialport qtdeclarative; do
      f="${QT6}/translations/${mod}_${lang}.qm"
      if [ -f "${f}" ]; then cp "${f}" "${OUT}/translations/"; fi
    done
  done
fi

# Strip debug info from everything we ship (MXE DLLs can carry a lot).
if [ "${BUILD_TYPE}" = "Release" ] && command -v "${MXE_TARGET}-strip" >/dev/null 2>&1; then
  find "${OUT}" -type f \( -iname '*.exe' -o -iname '*.dll' \) \
       -exec "${MXE_TARGET}-strip" --strip-unneeded {} + 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 7. Zip.
# ---------------------------------------------------------------------------
echo "==> Zipping"
ZIP="${DIST}/OpenModSim-${APP_VERSION}-windows-x64.zip"
( cd "$(dirname "${OUT}")" && rm -f "${ZIP}" && \
  (command -v zip >/dev/null && zip -qr "${ZIP}" "$(basename "${OUT}")" \
   || 7z a -tzip "${ZIP}" "$(basename "${OUT}")" >/dev/null) )

# ---------------------------------------------------------------------------
# 8. (Optional) NSIS installer, using the project's own script
#    (.github/win32/installer-win64.nsi) with makensis on Linux. Enable with
#    MAKE_INSTALLER=1. The upstream script runs vc_redist.x64.exe (MSVC
#    runtime); a MinGW build doesn't need it, so that section is removed.
# ---------------------------------------------------------------------------
if [ "${MAKE_INSTALLER}" = "1" ]; then
  echo "==> Building NSIS installer"
  command -v makensis >/dev/null 2>&1 || \
    { apt-get update && apt-get install -y --no-install-recommends nsis; }
  NSI_SRC="${APP}/.github/win32/installer-win64.nsi"
  [ -f "${NSI_SRC}" ] || die "NSIS script not found: ${NSI_SRC}"
  NSI="${SRC}/installer-win64-mingw.nsi"
  sed '/Section "Visual Studio Runtime"/,/SectionEnd/d' "${NSI_SRC}" > "${NSI}"
  SETUP="${DIST}/OpenModSim-${APP_VERSION}_x64.exe"
  makensis -V2 \
    -DVERSION="${APP_VERSION}" \
    -DMIN_WINDOWS_VERSION=10 \
    -DBUILD_PATH="${OUT}" \
    -DICON_FILE="${APP}/src/res/omodsim.ico" \
    -DWELCOMEFINISHPAGE_BITMAP="${APP}/.github/win32/nsis3-omodsim.bmp" \
    -DLICENSE_FILE="${APP}/src/res/license.txt" \
    -DOUTPUT_FILE="${SETUP}" \
    "${NSI}"
  echo "    Installer: ${SETUP}"
fi

echo ""
echo "=================================================================="
echo " Done. Windows build at: ${ZIP}"
if [ "${MAKE_INSTALLER}" = "1" ]; then echo " Installer:             ${SETUP}"; fi
echo "=================================================================="
