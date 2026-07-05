# Enabling HTTPS (SSL)

Black Candy Store runs behind [Thruster](https://github.com/basecamp/thruster), the HTTP/2 proxy that fronts the Rails/Puma server inside the container. Thruster can **obtain and renew Let's Encrypt certificates automatically**, so the simplest way to get HTTPS is already built into the image — no extra software, no Certbot, no reverse proxy required.

Three approaches are described below, from simplest to most flexible:

1. [Built-in automatic HTTPS with Thruster](#option-1--built-in-automatic-https-recommended) — recommended for most self-hosters.
2. [Terminate TLS at a reverse proxy](#option-2--terminate-tls-at-a-reverse-proxy) (Caddy, or Nginx + Certbot, or Traefik) — if you already run a proxy, host several apps on one machine, or need DNS-01 validation.
3. [Bring your own certificate](#option-3--bring-your-own-certificate) — purchased or internal-CA certificates.

---

## Option 1 — Built-in automatic HTTPS (recommended)

### Requirements

- A domain name (e.g. `music.example.com`) with a DNS `A`/`AAAA` record pointing at your server's public IP.
- Ports **80 and 443 reachable from the internet**. Let's Encrypt validates over them: port 80 handles the ACME challenge and redirects plain HTTP to HTTPS, and port 443 serves the app.

### Setup

Set the `TLS_DOMAIN` environment variable and publish both ports. That's the only change needed — if `TLS_DOMAIN` is unset, Thruster stays in HTTP-only mode.

```shell
docker run \
  -p 80:80 -p 443:443 \
  -e TLS_DOMAIN=music.example.com \
  -e SECRET_KEY_BASE=your_generated_secret \
  -v ./storage_data:/rails/storage \
  -v /media_data:/media_data -e MEDIA_PATH=/media_data \
  ghcr.io/ajeskey/blackcandystore:edge
```

On the first request for your domain, Thruster provisions a certificate, serves the app over HTTPS on 443, redirects plain HTTP on 80 to HTTPS, and renews the certificate automatically before it expires.

With docker compose:

```yaml
services:
  blackcandystore:
    image: ghcr.io/ajeskey/blackcandystore:edge
    ports:
      - "80:80"
      - "443:443"
    environment:
      TLS_DOMAIN: music.example.com
      SECRET_KEY_BASE: "your_generated_secret"
      MEDIA_PATH: /media
    volumes:
      - ./storage_data:/rails/storage
      - ./media:/media
```

### Persist the certificate storage

> [!IMPORTANT]
> Always mount `/rails/storage` to a volume when using built-in TLS. Thruster caches issued certificates under `STORAGE_PATH`, which defaults to `/rails/storage/thruster`. Persisting `/rails/storage` (as shown above) keeps your certificates across restarts and upgrades, so you don't re-request them every time — which also avoids hitting [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/).

### Testing without burning rate limits

While you confirm your DNS and firewall are correct, point Thruster at the Let's Encrypt **staging** endpoint. Staging certificates are not trusted by browsers, so use this only to verify issuance succeeds:

```shell
-e ACME_DIRECTORY=https://acme-staging-v02.api.letsencrypt.org/directory
```

When you switch back to production, clear the staging state first (e.g. remove `storage_data/thruster`) so a real certificate is requested.

### Multiple domains

`TLS_DOMAIN` accepts a comma-separated list, e.g. `TLS_DOMAIN=music.example.com,www.music.example.com`.

### Thruster TLS environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TLS_DOMAIN` | *(unset → HTTP only)* | Comma-separated domain(s) to provision a Let's Encrypt certificate for. Setting it enables HTTPS. |
| `HTTP_PORT` | `80` | Port for HTTP traffic (ACME challenge + redirect to HTTPS). |
| `HTTPS_PORT` | `443` | Port for HTTPS traffic. |
| `TARGET_PORT` | `3000` | Internal Puma port Thruster proxies to. Rarely changed. |
| `STORAGE_PATH` | `/rails/storage/thruster` | Where issued certificates are cached. Keep this on a persisted volume. |
| `ACME_DIRECTORY` | Let's Encrypt production | Set to the staging URL above while testing. |
| `EAB_KID` / `EAB_HMAC_KEY` | *(unset)* | External Account Binding credentials, if your ACME CA requires them. |

> [!NOTE]
> You generally do **not** need to set `FORCE_SSL` with built-in TLS — Thruster already redirects HTTP to HTTPS at the edge. `FORCE_SSL` is for the reverse-proxy setup below.

### If ports 80/443 are blocked

Some home ISPs block inbound 80/443, which prevents the HTTP-01/TLS-ALPN challenge from completing. In that case use a reverse proxy with **DNS-01** validation (Option 2) instead.

---

## Option 2 — Terminate TLS at a reverse proxy

Use a reverse proxy when you already run one, host multiple apps on a single machine, need DNS-01 validation (wildcards, or 80/443 blocked), or want to manage certificates centrally. Run the container **HTTP-only** (do not set `TLS_DOMAIN`) and let the proxy terminate TLS and forward to the container.

Set `FORCE_SSL=true` on the app so Rails builds `https` URLs and redirects insecure requests, and make sure the proxy forwards `X-Forwarded-Proto: https`.

### Caddy (automatic Let's Encrypt, simplest proxy)

`docker-compose.yml`:

```yaml
services:
  app:
    image: ghcr.io/ajeskey/blackcandystore:edge
    environment:
      SECRET_KEY_BASE: "your_generated_secret"
      FORCE_SSL: "true"
      MEDIA_PATH: /media
    volumes:
      - ./storage_data:/rails/storage
      - ./media:/media
    expose:
      - "80"        # internal only; not published to the host

  caddy:
    image: caddy:2
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
    depends_on:
      - app

volumes:
  caddy_data:
```

`Caddyfile`:

```
music.example.com {
    reverse_proxy app:80
}
```

Caddy obtains and renews the certificate automatically and sets `X-Forwarded-Proto` for you.

### Nginx + Certbot

1. Run the app HTTP-only, published only to localhost, e.g. `-p 127.0.0.1:8080:80`.
2. Install nginx and certbot on the host:

   ```shell
   sudo apt install nginx certbot python3-certbot-nginx
   ```

3. Add an nginx server block that proxies to the app:

   ```nginx
   server {
       listen 80;
       server_name music.example.com;

       location / {
           proxy_pass http://127.0.0.1:8080;
           proxy_set_header Host              $host;
           proxy_set_header X-Real-IP         $remote_addr;
           proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;
       }
   }
   ```

4. Obtain the certificate and let Certbot rewrite the server block for HTTPS:

   ```shell
   sudo certbot --nginx -d music.example.com
   ```

   Certbot installs a systemd timer that renews the certificate automatically. You can dry-run renewal with `sudo certbot renew --dry-run`.

### Traefik

If you run Traefik, expose the app service on port 80 and attach a router with your ACME (Let's Encrypt) certificate resolver via labels — Traefik then terminates TLS and forwards to the container. Ensure the entrypoint forwards `X-Forwarded-Proto`.

---

## Option 3 — Bring your own certificate

Thruster only manages Let's Encrypt certificates automatically; it cannot load a certificate you supply. To use a purchased certificate, an internal-CA certificate, or a wildcard, terminate TLS at a reverse proxy (Option 2) and point the proxy at your certificate files — for example Nginx's `ssl_certificate` / `ssl_certificate_key`, or a Caddy `tls /path/cert.pem /path/key.pem` directive.

---

## Verifying

```shell
curl -I https://music.example.com
```

Expect an `HTTP/2 200` (or a redirect from the `http://` URL to `https://`). Inspect the certificate with your browser, or:

```shell
openssl s_client -connect music.example.com:443 -servername music.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```
