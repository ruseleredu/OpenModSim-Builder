#!/usr/bin/env python3
"""
Serve a Windows COM port over TCP so the OpenModSim container can use it.

    pip install pyserial
    python com_tcp_bridge.py COM1 7001 --baud 9600 --parity N --stopbits 1

Then in docker-compose.yml:
    SERIAL_BRIDGES=ttyS0=host.docker.internal:7001
and pick "ttyS0" in OpenModSim's serial port list.

Serial settings (baud/parity/stop bits) are applied HERE on the real port;
the settings chosen inside OpenModSim do not reach the physical line.
Run one instance per COM port (different TCP ports).
"""
import argparse
import socket
import threading

import serial  # pyserial

PARITY = {"N": serial.PARITY_NONE, "E": serial.PARITY_EVEN, "O": serial.PARITY_ODD}
STOPBITS = {"1": serial.STOPBITS_ONE, "2": serial.STOPBITS_TWO}


def serial_to_socket(ser, conn, stop):
    while not stop.is_set():
        try:
            data = ser.read(ser.in_waiting or 1)
            if data:
                conn.sendall(data)
        except (OSError, serial.SerialException):
            break
    stop.set()


def socket_to_serial(ser, conn, stop):
    while not stop.is_set():
        try:
            data = conn.recv(4096)
        except OSError:
            break
        if not data:
            break
        ser.write(data)
    stop.set()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("com", help="serial port, e.g. COM1")
    ap.add_argument("tcp_port", type=int, help="TCP port to listen on, e.g. 7001")
    ap.add_argument("--baud", type=int, default=9600)
    ap.add_argument("--parity", choices=PARITY, default="N")
    ap.add_argument("--stopbits", choices=STOPBITS, default="1")
    ap.add_argument("--bytesize", type=int, choices=(7, 8), default=8)
    ap.add_argument("--bind", default="127.0.0.1",
                    help="listen address (default 127.0.0.1; use 0.0.0.0 if the container can't connect)")
    a = ap.parse_args()

    ser = serial.Serial(a.com, a.baud, bytesize=a.bytesize, parity=PARITY[a.parity],
                        stopbits=STOPBITS[a.stopbits], timeout=0.05)
    print(f"[bridge] {a.com} {a.baud} {a.bytesize}{a.parity}{a.stopbits} open")

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.bind, a.tcp_port))
    srv.listen(1)
    print(f"[bridge] listening on {a.bind}:{a.tcp_port}  (Ctrl+C to stop)")

    try:
        while True:
            conn, addr = srv.accept()
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            print(f"[bridge] client connected from {addr[0]}:{addr[1]}")
            ser.reset_input_buffer()
            stop = threading.Event()
            t1 = threading.Thread(target=serial_to_socket, args=(ser, conn, stop), daemon=True)
            t2 = threading.Thread(target=socket_to_serial, args=(ser, conn, stop), daemon=True)
            t1.start(); t2.start()
            stop.wait()
            conn.close()
            t1.join(1); t2.join(1)
            print("[bridge] client disconnected, waiting for reconnect")
    except KeyboardInterrupt:
        pass
    finally:
        srv.close()
        ser.close()


if __name__ == "__main__":
    main()
