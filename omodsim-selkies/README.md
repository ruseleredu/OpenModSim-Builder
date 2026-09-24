# OpenModSim in the Browser (Selkies)

[OpenModSim](https://github.com/sanny32/OpenModSim), a free Modbus slave/server simulator, compiled from source and served as a web desktop using LinuxServer's [Selkies base image](https://github.com/linuxserver/docker-baseimage-selkies) (Debian Trixie).

- Web UI at `https://localhost:3001` (or `http://localhost:3000`)
- Modbus TCP on port `502`
- Modbus RTU through physical COM ports, including Windows `COM1`, `COM2`… on Docker Desktop, via a serial-over-TCP bridge

```
openmodsim-selkies/
├── Dockerfile                  # 2-stage: build OpenModSim (Qt6) → Selkies runtime
├── docker-compose.yml
├── com_tcp_bridge.py           # Windows side: serves a COM port over TCP
└── root/
    ├── defaults/
    │   ├── autostart           # launches /usr/bin/omodsim2 when the desktop starts
    │   └── menu.xml            # right-click desktop menu
    └── etc/s6-overlay/s6-rc.d/
        └── svc-serialbridge/   # container side: TCP → /dev/ttyS* (socat)
```

---

## Quick start

```bash
docker compose up -d --build
```

Open **https://localhost:3001** and accept the self-signed certificate. The OpenModSim window starts automatically. If you close it, right-click the desktop and choose **Open ModSim**.

The first build compiles OpenModSim and takes a few minutes. Later builds use the Docker cache.

### Build options

| Build arg     | Default        | Purpose                                           |
| ------------- | -------------- | ------------------------------------------------- |
| `OMODSIM_REF` | `2.0.1`        | OpenModSim git tag or branch (`main` for latest) |
| `SELKIES_TAG` | `debiantrixie` | Selkies base image tag                            |

```bash
docker build --build-arg OMODSIM_REF=main -t openmodsim-selkies .
```

Keep the build stage (`debian:trixie`) and the runtime base on the same Debian release. Otherwise the compiled binary won't match the runtime libraries.

---

## Configuration

### Ports

| Port   | Use                   |
| ------ | --------------------- |
| `3000` | Web UI (HTTP)         |
| `3001` | Web UI (HTTPS)        |
| `502`  | Modbus TCP            |

The binary has `cap_net_bind_service`, so it can bind to port 502 while running as the non-root `abc` user.

### Environment variables

| Variable          | Example                                   | Purpose                                         |
| ----------------- | ----------------------------------------- | ----------------------------------------------- |
| `PUID` / `PGID`   | `1000`                                    | UID/GID that owns `/config`                     |
| `TZ`              | `America/Sao_Paulo`                       | Time zone                                       |
| `TITLE`           | `Open ModSim`                             | Browser tab title                               |
| `CUSTOM_USER`     | `admin`                                   | Web UI basic-auth user (default `abc`)          |
| `PASSWORD`        | `changeme`                                | Enables basic auth on the web UI                |
| `SERIAL_BRIDGES`  | `ttyS0=host.docker.internal:7001`         | Serial-over-TCP bridges (see below)             |
| `HARDEN_DESKTOP`  | `true`                                    | Single-app lockdown (no terminal, no sudo)      |
| `HARDEN_OPENBOX`  | `true`                                    | Restart the app automatically if it is closed   |

All other Selkies options (`SELKIES_*`, GPU, and so on) are documented in the [base image README](https://github.com/linuxserver/docker-baseimage-selkies#options).

### Persistent data

`./config` is mounted at `/config`, the desktop user's home. Save your OpenModSim projects there. Everything outside `/config` is reset when the image is rebuilt.

> **Security:** the built-in basic auth is only light protection. If the web UI is reachable from outside your LAN, put it behind a reverse proxy with proper authentication.

---

## Modbus RTU / serial ports

### Windows (Docker Desktop): COM1 → ttyS0

Docker Desktop runs Linux containers inside the WSL2 virtual machine, so Windows COM ports can't be passed to them directly. This setup bridges each COM port over TCP instead:

```
COM1 ── com_tcp_bridge.py ── TCP :7001 ── socat (in container) ── /dev/ttyS0 ── OpenModSim
       (Windows)                               (svc-serialbridge)
```

**1. On Windows**, start one bridge per COM port, using the RTU line settings:

```powershell
pip install pyserial
python com_tcp_bridge.py COM1 7001 --baud 9600 --parity N --stopbits 1
# more ports:
python com_tcp_bridge.py COM2 7002 --baud 19200 --parity E --stopbits 1
```

| Option       | Default     | Values                                      |
| ------------ | ----------- | ------------------------------------------- |
| `--baud`     | `9600`      | any                                         |
| `--parity`   | `N`         | `N`, `E`, `O`                               |
| `--stopbits` | `1`         | `1`, `2`                                    |
| `--bytesize` | `8`         | `7`, `8`                                    |
| `--bind`     | `127.0.0.1` | `0.0.0.0` if the container can't connect    |

**2. In `docker-compose.yml`**, map each TCP port to a `ttyS*` name:

```yaml
environment:
  - SERIAL_BRIDGES=ttyS0=host.docker.internal:7001 ttyS1=host.docker.internal:7002
```

**3. Restart and pick the port.** Run `docker compose up -d`, then in OpenModSim open the connection menu and select **ttyS0**.

Things to keep in mind:

- **The bridge sets the line parameters.** Baud rate, parity and stop bits come from `com_tcp_bridge.py`. The serial settings in OpenModSim don't reach the physical port.
- **Use `ttyS0`–`ttyS3` names.** OpenModSim only lists ports the kernel reports, and made-up names like `ttyVCOM0` won't appear. If `ttyS0` is missing, run `docker exec openmodsim ls /sys/class/tty` and use a `ttyS*` name from that list.
- **Reconnecting.** If the Windows bridge restarts, the container reconnects on its own (retrying every 2 s), but you have to disconnect and reconnect the port in OpenModSim.
- **Timing.** Modbus RTU relies on inter-frame gaps (3.5 character times), and the TCP hop can blur them. This is usually fine at normal baud rates. If you see occasional CRC errors, this is the likely cause.
- **Firewall.** If you use `--bind 0.0.0.0`, allow Python through Windows Firewall. The default `127.0.0.1` keeps the COM port off your LAN.

### Alternative for USB-serial adapters: usbipd

A USB adapter (FTDI, CP210x, CH340…) can be attached to the WSL2 VM itself. This keeps exact timing and lets OpenModSim set the line parameters:

```powershell
winget install usbipd
usbipd list                                  # find the adapter's BUSID
usbipd bind   --busid 2-3                    # admin prompt, once
usbipd attach --wsl --busid 2-3 --auto-attach
```

Then pass the device through in `docker-compose.yml`:

```yaml
devices:
  - /dev/ttyUSB0:/dev/ttyUSB0
group_add:
  - dialout
```

This only works if the WSL kernel includes a driver for your adapter.

### Linux hosts

Pass the device through with `devices:` and `group_add: [dialout]` as shown above. You don't need the bridge.

---

## Verifying

```bash
# Container and app
docker ps --filter name=openmodsim
docker exec openmodsim pgrep -a omodsim2
docker exec openmodsim getcap /usr/bin/omodsim2          # cap_net_bind_service=ep

# Web UI: expect 200 (401 without credentials if PASSWORD is set)
curl -sk -o /dev/null -w "%{http_code}\n" https://localhost:3001/

# Modbus TCP port open
curl -v --max-time 3 telnet://localhost:502 2>&1 | grep -iE "connected|refused"

# Real Modbus request: read holding register 1, unit 1
printf '\x00\x01\x00\x00\x00\x06\x01\x03\x00\x00\x00\x01' | nc -w 2 localhost 502 | xxd
#   → 0001 0000 0005 0103 02XX XX   (0183.. = Modbus exception, server still OK)

# With a Modbus client
mbpoll -m tcp -a 1 -t 4 -r 1 -c 10 -1 localhost

# Serial bridge
docker logs openmodsim | grep serial-bridge
docker exec openmodsim ls -l /dev/ttyS0                   # → /dev/pts/N
```

---

## Troubleshooting

| Symptom                                   | Check / fix                                                                                         |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Blank desktop, no OpenModSim window       | `docker logs openmodsim` for Qt plugin errors; right-click the desktop → Open ModSim                   |
| Port 502 closed                           | In OpenModSim, make sure a Modbus TCP connection on port 502 is active                              |
| Build fails at `apt-get install`          | A Trixie package was renamed (e.g. try `qt6-svg-dev` instead of `libqt6svg6-dev`)                    |
| `ttyS0` not in OpenModSim's port list     | Check `SERIAL_BRIDGES`, `docker logs openmodsim \| grep serial-bridge`, `ls /sys/class/tty`           |
| Bridge log shows repeated reconnects      | Windows bridge not running, wrong TCP port, or firewall; try `--bind 0.0.0.0`                       |
| `svc-serialbridge` doesn't start          | The `run` script needs LF line endings (the Dockerfile fixes CRLF and the executable bit)            |
| CRC / framing errors over the bridge      | Bridge timing; use a USB adapter with usbipd for strict RTU timing                                   |

---

## Credits

- [OpenModSim](https://github.com/sanny32/OpenModSim) by Alexandr Ananev, MIT License
- [docker-baseimage-selkies](https://github.com/linuxserver/docker-baseimage-selkies) by LinuxServer.io, GPL-3.0

This is an unofficial community setup, not affiliated with either project. See LinuxServer's [container branding guidelines](https://docs.linuxserver.io/general/container-branding/) before publishing an image built on their base.
