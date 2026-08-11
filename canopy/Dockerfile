# Static build: modernc.org/sqlite is pure Go, so CGO stays off and the result runs on a
# distroless base with no libc to patch. This service holds the APNs signing keys, so its
# attack surface is part of its threat model — the runtime image contains the binary, TLS
# roots, and nothing else.
FROM golang:1.26-bookworm AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/canopy ./cmd/canopy

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/canopy /canopy
# 8910 bambuddy, 8911 trellis, 8912 stl-texturize, 8913 here.
EXPOSE 8913
ENTRYPOINT ["/canopy"]
