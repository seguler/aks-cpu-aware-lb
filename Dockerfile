FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY cmd/backend ./cmd/backend
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /backend ./cmd/backend
FROM scratch
COPY --from=build /backend /backend
USER 65532:65532
ENTRYPOINT ["/backend"]
