# syntax=docker/dockerfile:1

ARG GO_VERSION=1.26.5
ARG GOLANG_IMAGE=golang:${GO_VERSION}-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2
ARG NODE_IMAGE=node:24-alpine
ARG VERSION=dev

FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS frontend
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY web/ ./
RUN npm run build

FROM --platform=$BUILDPLATFORM ${GOLANG_IMAGE} AS build
ARG TARGETOS
ARG TARGETARCH
ARG VERSION
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=frontend /src/internal/webconsole/dist ./internal/webconsole/dist
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build \
    -trimpath -buildvcs=false \
    -ldflags "-s -w -buildid= -X main.version=$VERSION" \
    -o /out/dans ./cmd/dans

FROM scratch
ARG VERSION
LABEL org.opencontainers.image.source="https://github.com/ncode/dans" \
      org.opencontainers.image.version="$VERSION"
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build --chmod=0555 /out/dans /usr/local/bin/dans
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/dans"]
CMD ["serve"]
