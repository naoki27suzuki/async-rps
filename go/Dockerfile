FROM golang:1.24 AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /bench .

FROM debian:bookworm-slim
# ps でスレッド数を見るため
RUN apt-get update && apt-get install -y --no-install-recommends procps && rm -rf /var/lib/apt/lists/*
COPY --from=build /bench /bench
EXPOSE 8000
CMD ["/bench"]
