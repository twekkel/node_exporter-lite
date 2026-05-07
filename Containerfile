FROM docker.io/nimlang/nim:2.2.10 AS builder

RUN DEBIAN_FRONTEND=noninteractive \
  apt-get update && apt-get install -y \
  musl \
  musl-dev \
  musl-tools \
  --no-install-recommends

WORKDIR /app
RUN nimble install -y zippy
COPY node_exporter.nim .

# Compile binary
RUN nim c -d:release --gcc.exe:musl-gcc --gcc.linkerexe:musl-gcc --mm:arc --opt:speed --define:lto --passC:"-flto" --passL:"-flto -static -s" node_exporter.nim

# Build binary only
FROM scratch AS binary
COPY --from=builder /app/node_exporter /node_exporter

# Build runnable image
FROM scratch
COPY --from=binary /node_exporter /node_exporter
ENTRYPOINT ["/node_exporter"]
