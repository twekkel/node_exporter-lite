#FROM docker.io/nimlang/nim:2.2.0-alpine-regular AS builder
FROM docker.io/nimlang/nim:latest-alpine-regular AS builder

# Add dependencies for statische compilation
RUN apk add --no-cache binutils gcc musl-dev

WORKDIR /app
RUN nimble install -y zippy
COPY node_exporter.nim .

# Compile binary
RUN nim c -d:danger --mm:arc --opt:speed --define:lto --panics:on --parallelBuild:0 --passC:"-flto=auto -march=native" --passL:"-flto=auto -static" node_exporter.nim && strip -s node_exporter

# Build binary only
FROM scratch AS binary
COPY --from=builder /app/node_exporter /node_exporter

# Build runnable image
FROM scratch
COPY --from=binary /node_exporter /node_exporter
ENTRYPOINT ["/node_exporter"]
