FROM gcr.io/distroless/static-debian12:nonroot
ARG TARGETARCH
COPY zharp-collector-linux-${TARGETARCH} /zharp-collector

EXPOSE 4317 4318 13133 55679

ENTRYPOINT ["/zharp-collector"]
CMD ["--config", "/etc/zharp-collector/config.yaml"]
