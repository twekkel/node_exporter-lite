# Temporary back to Alpine/Nim 2.2.6 due to
# https://github.com/nim-lang/docker-images/issues/88

#FROM docker.io/nimlang/nim:2.2.8-slim AS builder
#RUN apt-get update && \
#  DEBIAN_FRONTEND=noninteractive apt-get install -y \
#  musl \
#  musl-dev \
#  musl-tools \
#  --no-install-recommends

FROM docker.io/nimlang/nim:2.2.6-alpine-regular AS builder

RUN apk add --no-cache gcc musl-dev

WORKDIR /app
RUN nimble refresh && nimble install -y zippy
COPY node_exporter.nim .

# Compile binary
#RUN nim c -d:release --gcc.exe:musl-gcc --gcc.linkerexe:musl-gcc --mm:arc --opt:speed --define:lto --passC:"-flto" --passL:"-flto -static -s" node_exporter.nim
RUN nim c -d:release --mm:arc --opt:speed --define:lto --passC:"-flto" --passL:"-flto -static -s" node_exporter.nim

# Build binary only
FROM scratch AS binary
COPY --from=builder /app/node_exporter /node_exporter

# Build runnable image
FROM scratch
COPY --from=binary /node_exporter /node_exporter
ENTRYPOINT ["/node_exporter"]
