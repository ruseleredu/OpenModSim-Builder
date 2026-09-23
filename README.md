# OpenModSim: Windows x64 cross-build in Docker (MXE)

`Dockerfile` cross-builds Qt 6.11 for Windows with [MXE](https://mxe.cc) once and caches it in the image.
`build.sh` runs **inside** the container: it clones OpenModSim, builds `omodsim.exe` with MinGW-w64, bundles the DLLs and Qt plugins, and zips the result. It can also build an NSIS installer.

## 1. Build the image (one time, several hours)

```bash
docker build -t omodsim-mxe .
```

Build arguments:

| Argument | Default | Purpose |
|---|---|---|
| `MXE_REF` | `master` | MXE commit/tag to pin |
| `MXE_TARGET` | `x86_64-w64-mingw32.shared` | MXE target triplet |
| `MXE_PLUGIN_DIRS` | *(empty, GCC 11)* | e.g. `plugins/gcc14` for a newer GCC |
| `JOBS` | all cores | parallel jobs per package |

Build on an x86_64 host. The build needs about 15 GB of free disk.

## 2. Build OpenModSim inside the container (minutes)

```bash
mkdir -p dist
docker run --rm -v "$PWD/dist:/build/dist" omodsim-mxe
# -> dist/OpenModSim-<version>-windows-x64.zip
```

With the installer, a different branch, and Qlementine:

```bash
docker run --rm -v "$PWD/dist:/build/dist" \
  -e OMODSIM_REF=dev -e MAKE_INSTALLER=1 -e QLEMENTINE=1 omodsim-mxe
# -> dist/OpenModSim-<version>-windows-x64.zip
# -> dist/OpenModSim-<version>_x64.exe   (NSIS installer)
```

To build your own local checkout (reused as-is, not re-cloned):

```bash
docker run --rm -v "$PWD/dist:/build/dist" \
  -v "/path/to/OpenModSim:/build/src/OpenModSim" omodsim-mxe
```

To get an interactive shell and run it by hand:

```bash
docker run -it --rm -v "$PWD/dist:/build/dist" omodsim-mxe bash
/build/scripts/build.sh
```

| Variable | Default | Purpose |
|---|---|---|
| `OMODSIM_REF` | `main` | branch/tag to clone |
| `OMODSIM_REPO` | upstream GitHub | clone URL (e.g. your fork) |
| `QLEMENTINE` | `0` | `1` = experimental Qlementine style |
| `LTO` | `1` | `0` = disable link-time optimization (try it if linking fails) |
| `BUILD_TYPE` | `Release` | CMake build type |
| `MAKE_INSTALLER` | `0` | `1` = also build the NSIS setup `.exe` |
| `JOBS` | all cores | compile jobs |

## Output layout

This matches the official installer:

```
OpenModSim-windows-x64/
  omodsim.exe  qt.conf  license.txt  *.dll
  demos/  docs/jshelp.qch  docs/jshelp.qhc
  plugins/{platforms,styles,imageformats,iconengines,sqldrivers}/
  translations/
```

## How it differs from the upstream Windows build

- **MinGW instead of MSVC.** No Visual C++ runtime is needed, so the installer's `vc_redist` section is removed.
- **DLLs and plugins are collected with `objdump`** instead of `windeployqt`, which can't run on a Linux host.
- **`qhelpgenerator` is the distro's native one.** It comes from `qt6-documentation-tools` (Qt 6.4) because MXE's host Qt has no SQLite driver. The `.qch`/`.qhc` format is compatible.
- **Unit tests are turned off.** Their Windows executables can't run in the container.
