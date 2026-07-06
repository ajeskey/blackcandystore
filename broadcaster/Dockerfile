# Black Candy Store broadcaster.
#
# Runs the continuous MP3 encode loops and listener fan-out. Binds to loopback
# by design: it is a private data-plane service that Rails reverse-proxies
# public listeners to. It shells out to ffmpeg for the constant-bitrate encode,
# so ffmpeg must be present in the image.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    BROADCASTER_HOST=0.0.0.0 \
    BROADCASTER_PORT=9340

# ffmpeg powers the continuous constant-bitrate MP3 encode loop.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY broadcaster ./broadcaster

EXPOSE 9340

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,os,sys; sys.exit(0 if urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"BROADCASTER_PORT\",\"9340\")}/healthz').status==200 else 1)"

CMD ["python", "-m", "broadcaster"]
