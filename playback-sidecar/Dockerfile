# Black Candy Store playback sidecar.
#
# IMPORTANT: device discovery (AirPlay/Chromecast) relies on mDNS/multicast,
# which does NOT cross Docker's default bridge network. Run this container with
# `--network host` (Linux) so it can see devices on your LAN. See README.md.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    SIDECAR_HOST=0.0.0.0 \
    SIDECAR_PORT=9330

# libffi/openssl are needed by pyatv's cryptography dependency at runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libffi8 libssl3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY sidecar ./sidecar

EXPOSE 9330

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,os,sys; sys.exit(0 if urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"SIDECAR_PORT\",\"9330\")}/healthz').status==200 else 1)"

CMD ["python", "-m", "sidecar"]
