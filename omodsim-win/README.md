# OpenModSim: Windows x64 cross-build in Docker (prebuilt Qt)

Nothing is compiled when the image is built. The image contains:

- Ubuntu 24.04's MinGW-w64 cross-compiler (GCC 13, posix threads)
- the **official Qt MinGW binaries** for Windows, which OpenModSim links against
- the **official Qt binaries for Linux**, same version, for the tools that run during the build (`moc`, `uic`, `rcc`, `lupdate`, `qhelpgenerator`)

Both Qt builds are downloaded with [aqtinstall](https://github.com/miurahr/aqtinstall).
`build.sh` runs **inside** the container: it clones OpenModSim, builds `omodsim.exe`, bundles the DLLs and Qt plugins, and zips the result. It can also build an NSIS installer.

## 1. Build the image (a few minutes)

```bash
docker build -t omodsim-win .
```

| Build argument | Default | Purpose |
|---|---|---|
| `QT_VERSION` | `6.8.3` | Qt version. Use 6.8 or newer: those are built with MinGW 13, which matches Ubuntu's GCC 13 |
| `QT_MODULES` | `qtserialport qtserialbus qt5compat` | add-on modules. qtbase, qtdeclarative, qtsvg, qttools and qttranslations are always included |

## 2. Build OpenModSim inside the container

```bash
mkdir -p dist
docker run --rm -v "$PWD/dist:/build/dist" omodsim-win
# -> dist/OpenModSim-<version>-windows-x64.zip
```

With the installer, a different branch, and Qlementine:

```bash
docker run --rm -v "$PWD/dist:/build/dist" \
  -e OMODSIM_REF=dev -e MAKE_INSTALLER=1 -e QLEMENTINE=1 omodsim-win
# -> dist/OpenModSim-<version>-windows-x64.zip
# -> dist/OpenModSim-<version>_x64.exe   (NSIS installer)
```

To build your own local checkout (reused as-is, not re-cloned):

```bash
docker run --rm -v "$PWD/dist:/build/dist" \
  -v "/path/to/OpenModSim:/build/src/OpenModSim" omodsim-win
```

To get an interactive shell and run it by hand:

```bash
docker run -it --rm -v "$PWD/dist:/build/dist" omodsim-win bash
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

## Notes

- **Compiler runtime:** `libstdc++-6.dll`, `libgcc_s_seh-1.dll` and `libwinpthread-1.dll` come from the compiler that built the exe (GCC 13.2), not from Qt's older copies.
- **No `windeployqt`:** it is a Windows program. DLLs and plugins are collected with `objdump` instead.
- **Installer:** the project's own NSIS script (`.github/win32/installer-win64.nsi`) is used, with its Visual C++ runtime step removed, because MinGW builds don't need it.
- **CMake:** it is installed with pip, because OpenModSim needs 3.28.4 or newer and Ubuntu 24.04 ships 3.28.3.
- **Unit tests are turned off:** their Windows executables can't run in the container.
