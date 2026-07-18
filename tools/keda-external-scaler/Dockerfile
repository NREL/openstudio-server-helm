FROM golang:1.23 AS builder
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/keda-external-scaler ./main.go

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/keda-external-scaler /keda-external-scaler
USER nonroot:nonroot
ENTRYPOINT ["/keda-external-scaler"]
