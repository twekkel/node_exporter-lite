import asynchttpserver, asyncdispatch, logging, os, parseopt, posix, sets, strformat, strutils, zippy

const
  expVer = "1.0.0"
  nimVer = NimVersion

  DefaultMetric = "text/plain; version=0.0.4; charset=utf-8"
  HTMLText      = "text/html; charset=utf-8"
  PlainText     = "text/plain; charset=utf-8"
  Gzip          = ("content-encoding", "gzip")
  NoSniff       = ("x-content-type-options", "nosniff")

  PressureLabelsCpuSome    = "resource=\"cpu\",type=\"some\""
  PressureLabelsMemSome    = "resource=\"memory\",type=\"some\""
  PressureLabelsMemFull    = "resource=\"memory\",type=\"full\""
  PressureLabelsIoSome     = "resource=\"io\",type=\"some\""
  PressureLabelsIoFull     = "resource=\"io\",type=\"full\""

  CpuModeUser    = "mode=\"user\""
  CpuModeNice    = "mode=\"nice\""
  CpuModeSystem  = "mode=\"system\""
  CpuModeIdle    = "mode=\"idle\""
  CpuModeIowait  = "mode=\"iowait\""
  CpuModeIrq     = "mode=\"irq\""
  CpuModeSoftirq = "mode=\"softirq\""
  CpuModeSteal   = "mode=\"steal\""

const IndexPage = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Node Exporter Lite</title></head>
<body>
  <h1>Node Exporter Lite """ & expVer & """</h1>
  <p><a href="/metrics">Metrics</a></p>
  <p><a href="/health">Health</a></p>
</body>
</html>
"""

let clkTick = sysconf(SC_CLK_TCK).float

# --- Signals ---
proc handleSignal(sig: cint) {.noconv.} =
  stdout.writeLine "\nINFO: Received signal " & $sig & ". Exiting cleanly..."
  flushFile(stdout)
  quit(0)

discard signal(SIGINT,  handleSignal)
discard signal(SIGTERM, handleSignal)

# --- Helpers ---
# Reads /proc or /sys file directly into a buffer; returns slice length or -1
proc readProcInto(path: string, rootPath: string, buf: var array[4096, char]): int =
  let cleanPath = if path[0] == '/': path[1..^1] else: path
  let fullPath  = rootPath / cleanPath
  let fd = open(fullPath.cstring, O_RDONLY)
  if fd < 0: return -1
  let n = read(fd, addr buf[0], buf.len)
  discard close(fd)
  if n <= 0: return -1
  # Strip trailing whitespace/newlines in-place
  var e = n - 1
  while e >= 0 and (buf[e] == '\n' or buf[e] == '\r' or buf[e] == ' '): dec e
  result = e + 1

# Convenience wrapper returning a string (used for large files like /proc/stat)
proc readProc(path: string, rootPath: string): string =
  try:
    let cleanPath = if path[0] == '/': path[1..^1] else: path
    result = readFile(rootPath / cleanPath).strip()
  except:
    result = ""

proc parseListenAddress(val: string): (string, int) =
  try:
    if val.startsWith("["):
      let parts = val[1..^1].split("]:", 1)
      return (parts[0], parts[1].parseInt)
    let parts = val.rsplit(':', 1)
    let host = if parts[0] == "": "0.0.0.0" else: parts[0]
    return (host, parts[1].parseInt)
  except IndexDefect, ValueError:
    raise newException(ValueError, "Invalid address format: " & val)

# Copy n chars from a stack buffer into a fresh string
proc bufToString(buf: array[4096, char], n: int): string {.inline.} =
  result = newString(n)
  copyMem(addr result[0], unsafeAddr buf[0], n)

# Returns interfaces directly; skips loopback
proc listInterfaces(rootPath: string, result: var seq[string]) =
  result.setLen(0)
  let netPath = rootPath / "sys/class/net"
  if dirExists(netPath):
    for kind, path in walkDir(netPath):
      let name = lastPathPart(path)
      if name.len > 0 and name != "lo":
        result.add(name)

# --- String builder helpers (zero intermediate allocations) ---

var seenMetrics {.threadvar.}: HashSet[string]

# Writes HELP+TYPE header only once per metric name, then the metric line.
# All label strings must be pre-built by the caller.
proc metricLine(m: var string, name, mtype, help, value, labels: string) {.inline.} =
  if name notin seenMetrics:
    m.add("# HELP "); m.add(name); m.add(' '); m.add(help); m.add('\n')
    m.add("# TYPE "); m.add(name); m.add(' '); m.add(mtype); m.add('\n')
    seenMetrics.incl(name)
  m.add(name)
  if labels.len > 0:
    m.add('{'); m.add(labels); m.add('}')
  m.add(' '); m.add(value); m.add('\n')

proc metricLine(m: var string, name, mtype, help, value: string) {.inline.} =
  metricLine(m, name, mtype, help, value, "")

# --- Metrics ---
proc getMetrics(rootPath: var string): string =
  seenMetrics.clear()
  var m = newStringOfCap(16384)
  var buf: array[4096, char]

  # ── VERSION ──────────────────────────────────────────────────────────────
  m.metricLine("node_exporter_build_info", "gauge",
    "A metric with a constant '1' value labeled by version, and nimversion",
    "1", "version=\"" & expVer & "\",nimversion=\"" & nimVer & "\"")

  # ── UNAME ─────────────────────────────────────────────────────────────────
  var uts: Utsname
  if uname(uts) != -1:
    # Build label string once
    var ul = newStringOfCap(256)
    ul.add("machine=\"");    ul.add($(cast[cstring](addr uts.machine)));    ul.add("\",")
    ul.add("nodename=\"");   ul.add($(cast[cstring](addr uts.nodename)));   ul.add("\",")
    ul.add("release=\"");    ul.add($(cast[cstring](addr uts.release)));    ul.add("\",")
    ul.add("sysname=\"");    ul.add($(cast[cstring](addr uts.sysname)));    ul.add("\",")
    ul.add("version=\"");    ul.add($(cast[cstring](addr uts.version)));    ul.add("\"")
    m.metricLine("node_uname_info", "gauge",
      "Labeled system information as provided by the uname system call", "1", ul)

  # ── LOAD AVG ──────────────────────────────────────────────────────────────
  let loadLen = readProcInto("/proc/loadavg", rootPath, buf)
  if loadLen > 0:
    let loadStr = bufToString(buf, loadLen)
    let ws = loadStr.splitWhitespace()
    if ws.len >= 3:
      m.metricLine("node_load1",  "gauge", "1 minute load average",  ws[0])
      m.metricLine("node_load5",  "gauge", "5 minute load average",  ws[1])
      m.metricLine("node_load15", "gauge", "15 minute load average", ws[2])

  # ── ENTROPY ───────────────────────────────────────────────────────────────
  let eaLen = readProcInto("/proc/sys/kernel/random/entropy_avail", rootPath, buf)
  if eaLen > 0:
    m.metricLine("node_entropy_available_bits", "gauge",
      "Bits of available entropy", bufToString(buf, eaLen))

  let epLen = readProcInto("/proc/sys/kernel/random/poolsize", rootPath, buf)
  if epLen > 0:
    m.metricLine("node_entropy_pool_size_bits", "gauge",
      "Bits of entropy pool size", bufToString(buf, epLen))

  # ── MEMORY ────────────────────────────────────────────────────────────────
  const targetKeys = [
    "Active", "Buffers", "Cached", "Inactive",
    "MemAvailable", "MemFree", "MemTotal",
    "SReclaimable", "SwapCached", "SwapFree", "SwapTotal"
  ]

  try:
    var found = 0
    for line in lines(rootPath & "/proc/meminfo"):
      if found == targetKeys.len: break
      let p = line.splitWhitespace()
      if p.len < 2: continue
      let key = p[0].strip(chars = {':'})
      for tk in targetKeys:
        if key == tk:
          inc found
          try:
            let bytes = parseInt(p[1]) * 1024
            m.metricLine("node_memory_" & key & "_bytes", "gauge",
              "Memory information field " & key, $bytes)
          except: discard
          break
  except CatchableError: discard

  # ── CPU & SYSTEM STATS ────────────────────────────────────────────────────
  # Read /proc/stat once; parse everything in one pass
  try:
    let statContent = readProc("/proc/stat", rootPath)
    for line in statContent.splitLines():
      if line.len == 0: continue
      let p = line.splitWhitespace()
      if p.len < 2: continue
      case p[0]
      of "cpu":
        if p.len < 9: continue
        const h = "Seconds the CPU spent in each mode"
        const t = "counter"
        m.metricLine("node_cpu_seconds_total", t, h, $(p[1].parseFloat / clkTick), CpuModeUser)
        m.metricLine("node_cpu_seconds_total", t, h, $(p[2].parseFloat / clkTick), CpuModeNice)
        m.metricLine("node_cpu_seconds_total", t, h, $(p[3].parseFloat / clkTick), CpuModeSystem)
        m.metricLine("node_cpu_seconds_total", t, h, $(p[4].parseFloat / clkTick), CpuModeIdle)
        m.metricLine("node_cpu_seconds_total", t, h, $(p[5].parseFloat / clkTick), CpuModeIowait)
        m.metricLine("node_cpu_seconds_total", t, h, $(p[6].parseFloat / clkTick), CpuModeIrq)
        m.metricLine("node_cpu_seconds_total", t, h, $(p[7].parseFloat / clkTick), CpuModeSoftirq)
        m.metricLine("node_cpu_seconds_total", t, h, $(p[8].parseFloat / clkTick), CpuModeSteal)
      of "intr":
        m.metricLine("node_intr_total", "counter", "Total number of interrupts serviced", p[1])
      of "ctxt":
        m.metricLine("node_context_switches_total", "counter", "Total number of context switches", p[1])
      of "btime":
        m.metricLine("node_boot_time_seconds", "gauge", "Node boot time (Unix timestamp)", p[1])
      of "processes":
        m.metricLine("node_forks_total", "counter", "Total number of forks", p[1])
      of "procs_running":
        m.metricLine("node_procs_running", "gauge", "Number of processes in runnable state", p[1])
      of "procs_blocked":
        m.metricLine("node_procs_blocked", "gauge", "Number of processes blocked waiting for I/O", p[1])
      else: discard
  except CatchableError: discard

  # ── DISK I/O ──────────────────────────────────────────────────────────────
  type DiskData = tuple[dev, read, write: string]
  var diskList: seq[DiskData]
  try:
    let diskContent = readProc("/proc/diskstats", rootPath)
    for line in diskContent.splitLines():
      let p = line.splitWhitespace()
      if p.len < 11: continue
      let dev = p[2]
      if dev.startsWith("loop") or dev.startsWith("ram"): continue
      diskList.add((dev, $(p[5].parseBiggestInt * 512), $(p[9].parseBiggestInt * 512)))
  except CatchableError: discard

  for s in diskList:
    m.metricLine("node_disk_read_bytes_total", "counter",
      "Total bytes read from disk", s.read, "device=\"" & s.dev & "\"")
  for s in diskList:
    m.metricLine("node_disk_written_bytes_total", "counter",
      "Total bytes written to disk", s.write, "device=\"" & s.dev & "\"")

  # ── FILE DESCRIPTORS ──────────────────────────────────────────────────────
  let fnrLen = readProcInto("/proc/sys/fs/file-nr", rootPath, buf)
  if fnrLen > 0:
    let fnrParts = bufToString(buf, fnrLen).splitWhitespace()
    if fnrParts.len >= 3:
      m.metricLine("node_filefd_allocated", "gauge", "File descriptor statistics: allocated", fnrParts[0])
      m.metricLine("node_filefd_maximum",   "gauge", "File descriptor statistics: maximum",   fnrParts[2])

  # ── FILESYSTEM ────────────────────────────────────────────────────────────
  try:
    let mountContent = readProc("/proc/mounts", rootPath)
    var seenMounts: HashSet[string]   # O(1) vs seq O(n)

    # Convert filter lists to sets for O(1) lookup
    const unwantedFstypes    = toHashSet(["tmpfs","sysfs","proc","devtmpfs","devpts",
                                          "mqueue","debugfs","securityfs","configfs","autofs"])
    const unwantedDevParts   = ["loop", "ram"]
    const unwantedMntParts   = ["containers", "docker", "kubelet", "podman"]

    for line in mountContent.splitLines():
      let p = line.splitWhitespace()
      if p.len < 3: continue
      let dev = p[0]; let mountpoint = p[1]; let fstype = p[2]

      if not (dev.startsWith("/dev/") or dev == "overlay"):
        if fstype notin unwantedFstypes: continue

      var skip = false
      for ud in unwantedDevParts:
        if dev.contains(ud): skip = true; break
      if not skip:
        for um in unwantedMntParts:
          if mountpoint.contains(um): skip = true; break
      if skip: continue

      if mountpoint in seenMounts: continue
      seenMounts.incl(mountpoint)

      var fsStats: StatVfs
      let fullPath = (rootPath & mountpoint).replace("//", "/")
      if statvfs(fullPath.cstring, fsStats) != 0: continue

      let bsize = fsStats.f_bsize.uint64
      let total = fsStats.f_blocks.uint64 * bsize
      if total == 0: continue

      # Build label string once for all 6 filesystem metrics
      var fl = newStringOfCap(128)
      fl.add("device=\""); fl.add(dev)
      fl.add("\",mountpoint=\""); fl.add(mountpoint)
      fl.add("\",fstype=\""); fl.add(fstype); fl.add("\"")

      m.metricLine("node_filesystem_avail_bytes", "gauge",
        "Filesystem space available to non-root users in bytes",
        $(fsStats.f_bavail.uint64 * bsize), fl)
      m.metricLine("node_filesystem_size_bytes", "gauge",
        "Total filesystem size in bytes", $total, fl)
      m.metricLine("node_filesystem_free_bytes", "gauge",
        "Filesystem free space in bytes", $(fsStats.f_bfree.uint64 * bsize), fl)
      m.metricLine("node_filesystem_files", "gauge",
        "Filesystem total file nodes", $fsStats.f_files.uint64, fl)
      m.metricLine("node_filesystem_files_free", "gauge",
        "Filesystem free file nodes", $fsStats.f_ffree.uint64, fl)
      m.metricLine("node_filesystem_readonly", "gauge",
        "Filesystem read-only status",
        (if (culong(fsStats.f_flag) and culong(ST_RDONLY)) != 0: "1" else: "0"), fl)
  except CatchableError: discard

  # ── NETWORK ───────────────────────────────────────────────────────────────
  var interfaces: seq[string]
  listInterfaces(rootPath, interfaces)

  const netStats = [
    ("rx_bytes",   "receive_bytes_total",   "Total bytes received",              "counter"),
    ("tx_bytes",   "transmit_bytes_total",  "Total bytes transmitted",           "counter"),
    ("rx_packets", "receive_packets_total", "Total packets received",            "counter"),
    ("tx_packets", "transmit_packets_total","Total packets transmitted",         "counter"),
    ("rx_dropped", "receive_drop_total",    "Total receive packets dropped",     "counter"),
    ("tx_dropped", "transmit_drop_total",   "Total transmit packets dropped",    "counter"),
    ("rx_errors",  "receive_errs_total",    "Total receive errors detected",     "counter"),
    ("tx_errors",  "transmit_errs_total",   "Total transmit errors detected",    "counter"),
  ]

  # Prometheus convention: all series of one metric grouped together.
  # We read each stat file per device and store, then emit grouped.
  type NetVal = tuple[dev, val: string]
  var netBuf: array[netStats.len, seq[NetVal]]

  for dev in interfaces:
    let devLabel = "device=\"" & dev & "\""
    let statsDir = rootPath / "sys/class/net" / dev / "statistics"
    for i, (file, _, _, _) in netStats:
      let n = readProcInto("/" & statsDir[rootPath.len..^1] & "/" & file, rootPath, buf)
      if n > 0:
        netBuf[i].add((devLabel, bufToString(buf, n)))

  for i, (_, suffix, help, mtype) in netStats:
    let mname = "node_network_" & suffix
    for nv in netBuf[i]:
      m.metricLine(mname, mtype, help, nv.val, nv.dev)

  # ── PRESSURE (PSI) ────────────────────────────────────────────────────────
  # Read each /proc/pressure/<res> file ONCE and parse all fields in one pass.
  const pressureRes = ["cpu", "memory", "io"]
  const avgFields   = ["avg10=", "avg60=", "avg300=", "total="]
  const avgMetrics  = ["node_pressure_avg10", "node_pressure_avg60",
                       "node_pressure_avg300", "node_pressure_stall_seconds_total"]
  const avgHelp     = ["10s exponential moving average of share of capacity lost",
                       "60s exponential moving average of share of capacity lost",
                       "300s exponential moving average of share of capacity lost",
                       "Total stall time"]
  const avgTypes    = ["gauge", "gauge", "gauge", "counter"]

  const pressureLabels: array[3, array[2, string]] = [
    [PressureLabelsCpuSome, ""],
    [PressureLabelsMemSome, PressureLabelsMemFull],
    [PressureLabelsIoSome,  PressureLabelsIoFull],
  ]

  # Buffer: one seq per metric (avg10/avg60/avg300/total)
  type PressureEntry = tuple[labels, val: string]
  var pressBuf: array[4, seq[PressureEntry]]

  for ri, res in pressureRes:
    try:
      let content = readProc("/proc/pressure/" & res, rootPath)
      if content.len == 0: continue

      for line in content.splitLines():
        let parts = line.splitWhitespace()
        if parts.len < 5: continue
        let pType = parts[0]   # "some" or "full"
        if res == "cpu" and pType == "full": continue
        let li = if pType == "some": 0 else: 1
        let labels = pressureLabels[ri][li]

        for fi, field in avgFields:
          for tok in parts:
            if tok.startsWith(field):
              var val = tok[field.len..^1]
              if fi == 3:   # total — µs -> seconds
                try: val = $(parseFloat(val) / 1_000_000.0)
                except: break
              pressBuf[fi].add((labels, val))
              break
    except: discard

  # Emit grouped: all series for one metric together, HELP/TYPE printed once
  for fi in 0..3:
    for entry in pressBuf[fi]:
      m.metricLine(avgMetrics[fi], avgTypes[fi], avgHelp[fi], entry.val, entry.labels)

  return m

# --- Usage ---
proc displayUsage() =
  let usageText = fmt"""
Node Exporter Lite {expVer}
Usage: ./node_exporter [options]

Options:
  --web.listen-address=:9100    Address and port to listen on (default: 0.0.0.0:9100)
  --path.rootfs=/host           Path to the real host root filesystem (default: /)
  --help                        Show this help message
"""
  echo usageText
  quit(0)

# --- Server ---
proc main() {.async.} =
  const compressionLevel = BestSpeed

  let
    htmlHeaders    = newHttpHeaders([("content-type", HTMLText), NoSniff])
    genericHeaders = newHttpHeaders([("content-type", PlainText), NoSniff])
    gzipHeaders    = newHttpHeaders([("content-type", DefaultMetric), NoSniff, Gzip])
    noGzipHeaders  = newHttpHeaders([("content-type", DefaultMetric), NoSniff])

  var
    address  = "0.0.0.0"
    port     = 9100
    rootPath = "/"
    p        = initOptParser()

  for kind, key, val in p.getopt():
    case kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case key
      of "web.listen-address":
        if val.len > 0:
          try: (address, port) = parseListenAddress(val)
          except ValueError:
            echo "Error: '", val, "' is an invalid address/port"; quit(1)
      of "path.rootfs":
        if val.len > 0: rootPath = val
        else: echo "Error: --path.rootfs requires a value"; quit(1)
      else: displayUsage()
    of cmdArgument: displayUsage()

  addHandler(newConsoleLogger(fmtStr = "$levelname: "))

  let server = newAsyncHttpServer()

  proc cb(req: Request) {.async.} =
    let path = req.url.path
    if path == "/health":
      await req.respond(Http200, "OK\n", genericHeaders)
    elif path == "/metrics":
      let raw = getMetrics(rootPath)
      if req.headers.hasKey("Accept-Encoding") and "gzip" in req.headers["Accept-Encoding"]:
        await req.respond(Http200, compress(raw, compressionLevel, dfGzip), gzipHeaders)
      else:
        await req.respond(Http200, raw, noGzipHeaders)
    else:
      await req.respond(Http200, IndexPage, htmlHeaders)

  info("Starting Node Exporter Lite ", expVer, "\n",
       "Metrics available at http://", address, ":", port, "/metrics")
  await server.serve(Port(port), cb, address)

waitFor main()
