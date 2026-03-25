import asynchttpserver, asyncdispatch, logging, os, parseopt, posix, sets, strutils, times, zippy

const
  NoSniff = ("x-content-type-options", "nosniff")
  DefaultHTML = "text/html; charset=utf-8"
  DefaultMetric = "text/plain; version=0.0.4"

proc createHeaders(contentType: string, isGzip: bool = false): HttpHeaders =
  result = newHttpHeaders([("content-type", contentType), NoSniff])
  if isGzip:
    result.add("content-encoding", "gzip")

var
  noGzipHeaders {.threadvar.}: HttpHeaders
  gzipHeaders {.threadvar.}: HttpHeaders
  genericHeaders {.threadvar.}: HttpHeaders
  htmlHeaders {.threadvar.}: HttpHeaders

noGzipHeaders  = createHeaders(DefaultMetric)
gzipHeaders    = createHeaders(DefaultMetric, isGzip = true)
genericHeaders = createHeaders("text/plain; charset=utf-8")
htmlHeaders    = createHeaders(DefaultHTML)

const IndexPage = """
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Node Exporter Light</title></head>
<body>
  <h1>Node Exporter Light</h1>
  <p><a href="/metrics">Metrics</a></p>
</body>
</html>
"""

let clkTick = sysconf(SC_CLK_TCK).float

# --- Signals ---
# Takes care of SIGTERM
proc handleSignal(sig: cint) {.noconv.} =
  stdout.writeLine "\nINFO: Received signal " & $sig & ". Exiting cleanly..."
  flushFile(stdout)
  quit(0)

onSignal(SIGINT, SIGTERM):
  handleSignal(sig)

# --- Helpers ---
proc readProc(path: string, rootPath: string): string =
  try:
    let cleanPath = if path.startsWith("/"): path[1..^1] else: path
    let fullPath = rootPath / cleanPath
    result = readFile(fullPath).strip()
  except:
    result = ""

proc parseListenAddress(val: string): (string, int) =
  try:
    if val.startsWith("["):
      # Handle IPv6
      let parts = val[1..^1].split("]:", 1)
      return (parts[0], parts[1].parseInt)

    # Handle IPv4
    let parts = val.rsplit(':', 1)
    let host = if parts[0] == "": "0.0.0.0" else: parts[0]
    return (host, parts[1].parseInt)

  except IndexDefect, ValueError:
    raise newException(ValueError, "Invalid address format: " & val)

proc listInterfaces(rootPath: string): seq[string] =
  result = @[]
  let netPath = rootPath / "sys/class/net"

  if dirExists(netPath):
    for kind, path in walkDir(netPath):
      let name = lastPathPart(path)
      if name != "lo" and name != "":
        result.add(name)

# Helper for Prometheus lines with HELP en TYPE
var seenMetrics {.threadvar.}: HashSet[string]

proc metric(m: var string, name, mtype, help, value: string, labels = "") =
  # Alleen HELP/TYPE toevoegen als we deze 'name' nog niet hebben gezien
  if name notin seenMetrics:
    m.add("# HELP " & name & " " & help & "\n")
    m.add("# TYPE " & name & " " & mtype & "\n")
    seenMetrics.incl(name)

  if labels == "":
    m.add(name & " " & value & "\n")
  else:
    m.add(name & "{" & labels & "} " & value & "\n")

# --- Metrics ---
proc getMetrics(rootPath: var string): string =
  seenMetrics.clear()
  var m = ""

  # LOAD AVG & PROCESSES (Gauges/Counters)
  let loadRaw = readProc("/proc/loadavg", rootPath).splitWhitespace()
  if loadRaw.len >= 4:
    let procParts = loadRaw[3].split('/')
    if procParts.len == 2:
      let running = procParts[0]
      let total = procParts[1]

      m.metric("node_procs_total", "gauge", "Total number of processes", total)
      m.metric("node_load1", "gauge", "1 minute load average", loadRaw[0])
      m.metric("node_load5", "gauge", "5 minute load average", loadRaw[1])
      m.metric("node_load15", "gauge", "15 minute load average", loadRaw[2])

  # SYSTEM UPTIME
  let uptimeRaw = readProc("/proc/uptime", rootPath).splitWhitespace()
  if uptimeRaw.len >= 1:
    let bootTimestamp = epochTime() - uptimeRaw[0].parseFloat
    m.metric("node_boot_time_seconds", "gauge", "Node boot time (Unix timestamp)", $bootTimestamp)

  # MEMORY (Gauges)
  let memLines = readProc("/proc/meminfo", rootPath).splitLines()
  var memTotal, memAvailable: string = ""

  for line in memLines:
    let p = line.splitWhitespace()
    if p.len < 2: continue

    # De waarden in meminfo zijn in kB (Kibibytes), dus * 1024 voor bytes
    case p[0]:
    of "MemTotal:":
      memTotal = $(p[1].parseBiggestInt * 1024)
    of "MemAvailable:":
      memAvailable = $(p[1].parseBiggestInt * 1024)
    else: discard

  if memTotal != "":
    m.metric("node_memory_total_bytes", "gauge", "Total memory in bytes", memTotal)
  if memAvailable != "":
    m.metric("node_memory_available_bytes", "gauge", "Available memory in bytes", memAvailable)

  # CPU & SYSTEM STATS
  let statLines = readProc("/proc/stat", rootPath).splitLines()
  for line in statLines:
    let p = line.splitWhitespace()
    if p.len < 2: continue

    if p[0] == "cpu":
      let h = "Seconds the CPU spent in each mode"
      m.metric("node_cpu_seconds_total", "counter", h, $(p[1].parseFloat / clkTick), "mode=\"user\"")
      m.metric("node_cpu_seconds_total", "counter", h, $(p[3].parseFloat / clkTick), "mode=\"system\"")
      m.metric("node_cpu_seconds_total", "counter", h, $(p[4].parseFloat / clkTick), "mode=\"idle\"")
      m.metric("node_cpu_seconds_total", "counter", h, $(p[5].parseFloat / clkTick), "mode=\"iowait\"")

    elif p[0] == "ctxt":
      m.metric("node_context_switches_total", "counter", "Total number of context switches", p[1])

    elif p[0] == "processes":
      m.metric("node_forks_total", "counter", "Total number of forks", p[1])

    elif p[0] == "procs_running":
      m.metric("node_procs_running", "gauge", "Number of processes in runnable state", p[1])

    elif p[0] == "procs_blocked":
        m.metric("node_procs_blocked", "gauge", "Number of processes blocked waiting for I/O", p[1])

    elif p[0] == "intr":
      m.metric("node_intr_total", "counter", "Total number of interrupts serviced", p[1])

    elif p[0] == "softirq":
      m.metric("node_softirqs_total", "counter", "Total number of softirqs serviced", p[1])

  # DISK I/O (Counters)
  let diskLines = readProc("/proc/diskstats", rootPath).splitLines()

  type DiskData = tuple[dev, read, write: string]
  var statsList: seq[DiskData] = @[]

  for line in diskLines:
    let p = line.splitWhitespace()
    if p.len < 11: continue

    let dev = p[2]
    if dev.startsWith("loop") or dev.startsWith("ram"): continue

    let readBytes = $(p[5].parseBiggestInt * 512)
    let writeBytes = $(p[9].parseBiggestInt * 512)

    statsList.add((dev, readBytes, writeBytes))

  for s in statsList:
    m.metric("node_disk_read_bytes_total", "counter",
             "Total bytes read from disk", s.read, "device=\"" & s.dev & "\"")

  for s in statsList:
    m.metric("node_disk_written_bytes_total", "counter",
             "Total bytes written to disk", s.write, "device=\"" & s.dev & "\"")

  # FILESYSTEM (Gauge)
  let mountLines = readProc("/proc/mounts", rootPath).splitLines()
  var seenMounts: seq[string] = @[]

  for line in mountLines:
    let p = line.splitWhitespace()
    if p.len < 3: continue

    let dev = p[0]
    let mountpoint = p[1]
    let fstype = p[2]

    if not (dev.startsWith("/dev/") or dev == "overlay"): continue
    if dev.contains("loop") or dev.contains("ram") or mountpoint.contains("containers"):
      continue

    if mountpoint in seenMounts: continue
    seenMounts.add(mountpoint)

    var fsStats: StatVfs
    let fullPath = (rootPath & mountpoint).replace("//", "/")

    if statvfs(fullPath.cstring, fsStats) == 0:
      let availBytes = fsStats.f_bavail.uint64 * fsStats.f_bsize.uint64
      let totalBytes = fsStats.f_blocks.uint64 * fsStats.f_bsize.uint64

      if totalBytes > 0:
        let labels = "device=\"" & dev & "\",mountpoint=\"" & mountpoint & "\""

        m.metric("node_filesystem_avail_bytes", "gauge",
                 "Filesystem space available to non-root users in bytes", $availBytes, labels)
        m.metric("node_filesystem_size_bytes", "gauge",
                 "Total filesystem size in bytes", $totalBytes, labels)

  # NETWORK (Counters via /sys)
  let interfaces = listInterfaces(rootPath)

  for dev in interfaces:
    try:
      let rx = readProc("/sys/class/net/" & dev & "/statistics/rx_bytes", rootPath).strip()
      if rx != "":
        m.metric("node_network_receive_bytes_total", "counter",
                 "Total bytes received", rx, "device=\"" & dev & "\"")
    except IOError:
      continue

  for dev in interfaces:
    try:
      let tx = readProc("/sys/class/net/" & dev & "/statistics/tx_bytes", rootPath).strip()
      if tx != "":
        m.metric("node_network_transmit_bytes_total", "counter",
                 "Total bytes transmitted", tx, "device=\"" & dev & "\"")
    except IOError:
      continue

  return m

# --- Usage ---
proc displayUsage() =
  echo """
Node Exporter Light
Usage: ./node_exporter [options]

Options:
  --web.listen-address=:9100    Address and port to listen on (default: 0.0.0.0:9100)
  --path.rootfs=/host           Path to the real host root filesystem (default: /)
  --help                        Show this help message
"""
  quit(0)

# --- Server ---
proc main() {.async.} =
  const compressionLevel = BestSpeed
  var address = "0.0.0.0"
  var port = 9100
  var p = initOptParser()
  var rootPath = "/"

  for kind, key, val in p.getopt():
    case kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case key
      of "web.listen-address":
        if val != "":
          try:
            (address, port) = parseListenAddress(val)
          except ValueError:
            echo "Error: '", val, "' is an invalid address/port"
            quit(1)
      of "path.rootfs":
        if val != "":
          rootPath = val
        else:
          echo "Error: --path.rootfs requires a value"
          quit(1)
      else:
        displayUsage()
    of cmdArgument:
      displayUsage()

  var L = newConsoleLogger(fmtStr = "$levelname: ")
  addHandler(L)

  var server = newAsyncHttpServer()
  proc cb(req: Request) {.async, gcsafe.} =
    if req.url.path == "/health" or req.url.path == "/":
      await req.respond(Http200, "OK\n", genericHeaders)
      return

    if req.url.path != "/metrics":
      await req.respond(Http200, IndexPage, htmlHeaders)
      return

    let rawMetrics = getMetrics(rootPath)

    #if "gzip" in req.headers.getOrDefault("Accept-Encoding"):
    if req.headers.hasKey("Accept-Encoding") and "gzip" in req.headers["Accept-Encoding"]:
      await req.respond(Http200, compress(rawMetrics, compressionLevel, dfGzip), gzipHeaders)
    else:
      await req.respond(Http200, rawMetrics, noGzipHeaders)

  info("Starting Node Exporter Light\n",
       "Listening on http://",  address, ":", port, "\n",
       "Metrics available at /metrics")
  await server.serve(Port(port), cb, address)

waitFor main()
