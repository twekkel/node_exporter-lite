[README.md](https://github.com/user-attachments/files/26249566/README.md)

[![main](https://github.com/twekkel/node_exporter-lite/actions/workflows/ci.yml/badge.svg)](https://github.com/twekkel/node_exporter-lite/actions/workflows/ci.yml)

# Node Exporter Lite

## Introduction

Ultra‑light drop‑in replacement for Prometheus [node_exporter](https://github.com/prometheus/node_exporter), written in [Nim](https://nim-lang.org) and compiled into a single static binary with zero external dependencies.

A minimal, high‑performance implementation of the standard `node_exporter` metrics with extremely low memory and CPU usage. Ideal for resource‑constrained systems, embedded devices, and environments where a compact, easy‑to‑distribute exporter is required.

---

## Key Features

* **Small Footprint:** Container images and binaries are typically around **400 kB**.
* **Memory (RSS):** Typically **under 1MB** under normal load.
* **CPU Usage:** Negligible (<0.1% on most modern systems).
* **Zero Dependencies:** Statically linked against `musl`; runs on any Linux distro.
* **Modern Nim:** Leverages `ARC` memory management and `LTO` (Link Time Optimization) for maximum speed.
* **Lightweight Drop‑in Replacement:** Compatible with Prometheus’ standard node_exporter metrics, making it a seamless, ultra‑small alternative for resource‑constrained systems.

---

## Official node_exporter vs lite version

| Aspect         | Node Exporter (official)       | node_exporter-lite          |
| -------------- | ------------------------------ | --------------------------- |
| Language       | Go                             | Nim                         |
| Binary size    | ~22 MB                         | ~500 kB                     |
| Footprint      | ~23 MB                         | < 1 MB                      |
| Collectors     | Many (modular, configurable)   | fixed                       |
| Configuration  | Extensive flags                | Little to none              |
| Resource usage | Higher (depends on collectors) | Low and predictable         |
| Scope          | Full system observability      | Core system metrics only    |
| Complexity     | Higher                         | Very low                    |
| Use case       | General-purpose monitoring     | Lightweight                 |

### Equivalent configuration

node_exporter-lite roughly provides the same core metrics as running the official Node Exporter with a minimal collector set:

```
node_exporter \
  --collector.disable-defaults \
  --collector.cpu \
  --collector.diskstats \
  --collector.entropy \
  --collector.filefd \
  --collector.filesystem \
  --collector.loadavg \
  --collector.meminfo \
  --collector.netdev \
  --collector.pressure \
  --collector.stat \
  --collector.time \
  --collector.uname
```

## Building

This project uses a multi-stage `Containerfile` to ensure a consistent build environment. You do not need Nim or GCC installed on your host machine.

### Build as a Container Image

To build a runnable container image for Podman or Docker, run:
```
podman build -t node_exporter .
```
Once the image is built, start it with:
```
podman run \
  --detach \
  --name node_exporter \
  --publish 9100:9100 \
  -v /proc:/host/proc:ro \
  -v /sys:/host/sys:ro \
  node_exporter \
    --path.rootfs=/host
```

This setup mounts the host’s /proc and /sys into the container so that the exporter can read system metrics from the host instead of the container environment.

If you want the exporter to access host-level process information, you can add ```--pid=host```.

### Build a static binary for the host

To produce a fully self‑contained static binary you can run directly on the host, build the image with:
```
podman build --target binary -o ./bin .
```
This places the compiled binary in ./bin.
Run it with:
```
./bin/node_exporter
```

## Options

| Flag | Description |
|------|-------------|
| `--web.listen-address=[ADDR]:PORT` | Address and port to listen on (default: `0.0.0.0:9100`) |
| `--path.rootfs=/host` | Path to the real host root filesystem (default: `/`) |
| `--help` | Show this help message |
