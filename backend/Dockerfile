FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /routing-api .

FROM alpine:3.23
RUN apk add --no-cache ca-certificates && adduser -D -u 10001 roadscout
COPY --from=build /routing-api /usr/local/bin/routing-api
USER roadscout
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/routing-api"]
