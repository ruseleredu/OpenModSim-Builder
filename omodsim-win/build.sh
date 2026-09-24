#!/usr/bin/env bash
# ============================================================================
# Checkout OpenModSim, cross-build it for Windows x64 with MinGW-w64 against
# the PREBUILT official Qt MinGW binaries, and package a dist.
# Runs INSIDE the container built from the Dockerfile.
#
# Environment knobs:
#   OMODSIM_REF=main        branch/tag to clone (ignored if the source dir is
#                           already present, e.g. a mounted local checkout)
#   QLEMENTINE=0|1          experimental Qlementine app style (Qt >= 6.8)
#   LTO=1|0                 link-time optimization (upstream turns it on)
#   BUILD_TYPE=Release
#   MAKE_INSTALLER=0|1      also build an NSIS setup .exe with makensis
#   QHELPGENERATOR=<path>   override the native qhelpgenerator
#   JOBS=<n>                parallel compile jobs (default: all cores)
# ============================================================================
set -euo pipefail

: "${QT_ROOT:=/opt/qt}"
: "${QT_VERSION:=6.8.3}"
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

QT6="${QT_ROOT}/${QT_VERSION}/mingw_64"     # target Qt (Windows, MinGW)
QT_HOST="${QT_ROOT}/${QT_VERSION}/gcc_64"   # host Qt (Linux build tools)

# Ubuntu's MinGW-w64 cross toolchain. The -posix variants are required:
# Qt's MinGW builds use the posix thread model (libwinpthread).
TRIPLET=x86_64-w64-mingw32
CC="${TRIPLET}-gcc-posix"
CXX="${TRIPLET}-g++-posix"
OBJDUMP="${TRIPLET}-objdump"
STRIP="${TRIPLET}-strip"

export GIT_TERMINAL_PROMPT=0       # never hang on a username/password prompt
export QT_QPA_PLATFORM=offscreen   # native Qt tools (qhelpgenerator) run headless

# ---------------------------------------------------------------------------
# 0. Sanity checks.
# ---------------------------------------------------------------------------
die() { echo "!! $*" >&2; exit 1; }

[ -f "${QT6}/lib/cmake/Qt6/Qt6Config.cmake" ]     || die "Target Qt not found at ${QT6}"
[ -f "${QT_HOST}/lib/cmake/Qt6/Qt6Config.cmake" ] || die "Host Qt not found at ${QT_HOST}"
for t in "${CC}" "${CXX}" "${TRIPLET}-windres" "${OBJDUMP}" cmake ninja; do
  command -v "${t}" >/dev/null 2>&1 || die "${t} not found in PATH"
done

# Qt's .a import libraries only link with a compatible GCC (Qt 6.8+: GCC 13).
GCC_MAJOR="$("${CXX}" -dumpversion | cut -d. -f1)"
echo "==> Compiler: ${CXX} ($("${CXX}" -dumpfullversion))"
if [ "${GCC_MAJOR}" -lt 13 ]; then
  echo "    WARNING: Qt ${QT_VERSION} MinGW binaries are built with GCC 13; linking may fail."
fi

# qhelpgenerator runs at BUILD time, so it must be a native Linux binary.
# Prefer the host Qt's (same version as the target); fall back to the
# distro's (qt6-documentation-tools) if it can't start.
if [ -z "${QHELPGENERATOR:-}" ]; then
  for c in "${QT_HOST}/libexec/qhelpgenerator" "${QT_HOST}/bin/qhelpgenerator" \
           /usr/lib/qt6/libexec/qhelpgenerator; do
    if [ -x "${c}" ] && "${c}" -v >/dev/null 2>&1; then QHELPGENERATOR="${c}"; break; fi
  done
fi
[ -n "${QHELPGENERATOR:-}" ] || die "no working qhelpgenerator found (set QHELPGENERATOR=...)"

echo "==> Qt (target):    ${QT6}"
echo "==> Qt (host):      ${QT_HOST}"
echo "==> cmake:          $(cmake --version | head -n1)"
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
# 2. CMake toolchain file for the MinGW-w64 cross-compiler.
#    Find mode ONLY for libraries/headers/packages keeps CMake from picking up
#    Linux libraries; programs (moc, lupdate, ...) always come from the host.
#    gcc-ar/gcc-ranlib are set explicitly so LTO static libraries work.
# ---------------------------------------------------------------------------
TOOLCHAIN="${SRC}/mingw-w64-x86_64.cmake"
cat > "${TOOLCHAIN}" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(CMAKE_C_COMPILER   ${CC})
set(CMAKE_CXX_COMPILER ${CXX})
set(CMAKE_RC_COMPILER  ${TRIPLET}-windres)
set(CMAKE_C_COMPILER_AR       ${TRIPLET}-gcc-ar-posix)
set(CMAKE_CXX_COMPILER_AR     ${TRIPLET}-gcc-ar-posix)
set(CMAKE_C_COMPILER_RANLIB   ${TRIPLET}-gcc-ranlib-posix)
set(CMAKE_CXX_COMPILER_RANLIB ${TRIPLET}-gcc-ranlib-posix)

set(CMAKE_FIND_ROOT_PATH /usr/${TRIPLET} ${QT6})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# ---------------------------------------------------------------------------
# 3. Configure.
#    - CMAKE_PREFIX_PATH / QT_HOST_PATH  target Qt to link, host Qt for tools.
#    - OMODSIM_BUILD_TESTS=OFF     test executables can't run on the Linux host.
#    - QHELP_GENERATOR_EXECUTABLE  native tool, see step 0.
#    - LTO=0 overrides the upstream set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
#      via the per-config variable, which takes precedence.
# ---------------------------------------------------------------------------
echo "==> Configuring"
rm -rf "${BUILD}"
QLEM_OPT=OFF; if [ "${QLEMENTINE}" = "1" ]; then QLEM_OPT=ON; fi

CMAKE_ARGS=(
  -S "${APP}/src" -B "${BUILD}" -G Ninja
  -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}"
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
  -DCMAKE_PREFIX_PATH="${QT6}"
  -DQT_HOST_PATH="${QT_HOST}"
  -DUSE_QT6=ON
  -DOMODSIM_BUILD_TESTS=OFF
  -DUSE_QLEMENTINE_APP_STYLE="${QLEM_OPT}"
  -DQHELP_GENERATOR_EXECUTABLE="${QHELPGENERATOR}"
)
if [ "${LTO}" = "0" ]; then
  CMAKE_ARGS+=("-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_${BUILD_TYPE^^}=OFF")
fi
cmake "${CMAKE_ARGS[@]}"

# ---------------------------------------------------------------------------
# 4. Build.
# ---------------------------------------------------------------------------
echo "==> Building"
cmake --build "${BUILD}" -j "${JOBS}"

EXE="$(find "${BUILD}" -maxdepth 2 -iname 'omodsim.exe' | head -n1)"
[ -n "${EXE}" ] || die "omodsim.exe not found -- build failed"
echo "==> Built: ${EXE}"

# ---------------------------------------------------------------------------
# 5. Stage the app with the same layout as the official Windows installer:
#      omodsim.exe, demos/, docs/jshelp.{qch,qhc}, plugins/, translations/
#    (We don't use 'cmake --install': its Windows rules call windeployqt,
#    which is a Windows program. Steps 6-7 do its job instead.)
# ---------------------------------------------------------------------------
echo "==> Staging ${OUT}"
rm -rf "${OUT}"; mkdir -p "${OUT}/docs"
cp "${EXE}" "${OUT}/omodsim.exe"
cp -a "${APP}/demos" "${OUT}/demos"
cp "${BUILD}"/docs/jshelp.qch "${BUILD}"/docs/jshelp.qhc "${OUT}/docs/"
if [ -f "${APP}/src/res/license.txt" ]; then cp "${APP}/src/res/license.txt" "${OUT}/"; fi

# ---------------------------------------------------------------------------
# 6. Resolve DLL dependencies recursively with objdump.
#    The compiler's own runtime (libstdc++-6, libgcc_s_seh-1, libwinpthread-1)
#    is searched FIRST, so the exe ships with the runtime it was built with
#    rather than the older copies bundled in Qt's mingw_64/bin.
# ---------------------------------------------------------------------------
echo "==> Resolving DLL dependencies"
SEARCH_DIRS=(
  "$(dirname "$("${CXX}" -print-file-name=libstdc++-6.dll)")"
  "$(dirname "$("${CXX}" -print-file-name=libwinpthread-1.dll)")"
  "/usr/${TRIPLET}/lib"
  "${QT6}/bin"
)

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
# 7. Qt plugins -> plugins/<group>/, the same set the upstream windeployqt
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

# Strip our own exe (Qt's DLLs are already release builds).
if [ "${BUILD_TYPE}" = "Release" ]; then
  "${STRIP}" --strip-unneeded "${OUT}/omodsim.exe" || true
fi

# ---------------------------------------------------------------------------
# 8. Zip.
# ---------------------------------------------------------------------------
echo "==> Zipping"
ZIP="${DIST}/OpenModSim-${APP_VERSION}-windows-x64.zip"
rm -f "${ZIP}"
if command -v zip >/dev/null 2>&1; then
  ( cd "$(dirname "${OUT}")" && zip -qr "${ZIP}" "$(basename "${OUT}")" )
else
  ( cd "$(dirname "${OUT}")" && 7z a -tzip "${ZIP}" "$(basename "${OUT}")" >/dev/null )
fi

# ---------------------------------------------------------------------------
# 9. (Optional) NSIS installer, using the project's own script
#    (.github/win32/installer-win64.nsi) with makensis on Linux. Enable with
#    MAKE_INSTALLER=1. The upstream script runs vc_redist.x64.exe (MSVC
#    runtime); a MinGW build doesn't need it, so that section is removed.
# ---------------------------------------------------------------------------
if [ "${MAKE_INSTALLER}" = "1" ]; then
  echo "==> Building NSIS installer"
  command -v makensis >/dev/null 2>&1 || die "makensis not found (apt install nsis)"
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
