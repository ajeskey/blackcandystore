<p align='center'>
  <img alt='Black Candy Store logo' width='200' src='https://raw.githubusercontent.com/ajeskey/blackcandystore/master/Black-Candy-Store-Logo.png'>
</p>

# Black Candy Store
[![CI](https://github.com/ajeskey/blackcandystore/actions/workflows/ci.yml/badge.svg)](https://github.com/ajeskey/blackcandystore/actions/workflows/ci.yml)

Black Candy Store is a self-hosted music streaming server built on Black Candy — your personal music center.

> [!NOTE]
> **Black Candy Store is an expansion of the [Black Candy](https://github.com/blackcandy-org/black_candy) project, not a separate product.** It builds directly on Black Candy and adds multi-library management, cross-server library sharing, and automatic catalog mirroring. Everything that makes Black Candy a great music server — the web player, browsing, playlists, and more — comes from the upstream Black Candy project and its contributors. See [Acknowledgments](#acknowledgments) for full credit.

## Features

Black Candy Store keeps everything Black Candy already offers and layers new multi-library and cross-server capabilities on top. Features introduced by this expansion are marked _(Store)_; everything else is provided by upstream Black Candy.

- **Streaming and browsing** — browse, search, filter, and sort your songs, albums, and artists, and stream them from the web player (native mobile apps coming soon).
- **Playlists and favorites** — build playlists, manage a playback queue, and favorite the songs you love.
- **Multiple libraries** _(Store)_ — organize your music into several named libraries, each backed by its own media path, instead of one monolithic collection. Each user browses one active library at a time. Existing single-media-path installs keep working: the pre-existing collection becomes the default library automatically.
- **Cross-server library sharing** _(Store)_ — share a single library with someone on another Black Candy server using an invite code. They redeem it to browse and play your library as if it were their own, and you can revoke access at any time.
- **Automatic catalog mirroring** _(Store)_ — when a shared library is redeemed across servers, the redeeming server keeps a fast, local, metadata-only mirror of the remote catalog that stays in sync automatically (a periodic pull plus a best-effort push nudge). Browsing a shared library is served from local queries — no live round-trip per request — while audio and artwork are streamed and proxied live at play time. The mirror stores no audio or artwork bytes.
- **Source preference** _(Store)_ — when the same track is available from more than one library or server, choose whether to prefer your own server or the highest-quality copy.
- **Playback modes** — cast audio directly from the player to AirPlay/Chromecast devices (`client_cast`), or have the server stream audio to output devices (`server_playback`). Server-side output is handled by an optional [playback sidecar](docs/playback-sidecar.md); without it, `client_cast` still works and the Playback Devices page degrades gracefully.
- **DAAP / RSP media clients** — expose your local, authorized content to external DAAP and RSP clients (each toggleable in settings).

See the [API documentation](docs/api/README.md) for the full HTTP API, including the [Libraries](docs/api/sections/libraries.md), [Sharing](docs/api/sections/sharing.md), and [Playback & source preference](docs/api/sections/playback.md) sections, plus the server-to-server [Federation API](docs/api/sections/federation.md) that powers cross-server sharing and catalog mirroring.

## Installation

Black Candy Store ships as a Docker image. You can run it like this.

```shell
docker run -p 80:80 ghcr.io/ajeskey/blackcandystore:latest
```

That's all. Now, you can access either http://localhost or http://host-ip in a browser, and use initial admin user to log in (email: admin@admin.com, password: foobar).

## Upgrade

> [!IMPORTANT]
> If you upgrade to a new version, you need to read the upgrade guide carefully before upgrade. Because there may be some breaking changes in a new version.
>
> Please check the [Upgrade Guide](https://github.com/ajeskey/blackcandystore/blob/master/docs/upgrade.md) for upgrading to a new version.

To upgrade, pull the new image from the remote, then remove the old container and create a new one.

```shell
docker pull ghcr.io/ajeskey/blackcandystore:latest
docker stop <your_blackcandystore_container>
docker rm <your_blackcandystore_container>
docker run <OPTIONS> ghcr.io/ajeskey/blackcandystore:latest
```

With docker compose, you can upgrade like this:

```shell
docker pull ghcr.io/ajeskey/blackcandystore:latest
docker-compose down
docker-compose up
```

## Mobile Apps

Native mobile apps for Black Candy Store are coming soon.

## Configuration

### HTTPS / SSL

Black Candy Store can serve HTTPS with automatic Let's Encrypt certificates out of the box — no reverse proxy or Certbot required. Set `TLS_DOMAIN` to your domain and publish port 443:

```shell
docker run -p 80:80 -p 443:443 -e TLS_DOMAIN=music.example.com -v ./storage_data:/rails/storage ghcr.io/ajeskey/blackcandystore:edge
```

The certificate is provisioned on first request and renewed automatically (cached under the persisted `/rails/storage`, so keep that volume mounted). Your domain's DNS must point at the server and ports 80 and 443 must be reachable.

Prefer to terminate TLS at a reverse proxy (Caddy, Nginx + Certbot, Traefik) or bring your own certificate? See the full guide: **[Enabling HTTPS (SSL)](docs/https.md)**.

### Port Mapping

Black Candy Store exposes port 80. If you want to be able to access it from the host, you can use the `-p` option to map the port.

```shell
docker run -p 3000:80 ghcr.io/ajeskey/blackcandystore:latest
```

### Media Files Mounts

You can mount media files from the host to the container and use the `MEDIA_PATH` environment variable to set the media path.

```shell
docker run -v /media_data:/media_data -e MEDIA_PATH=/media_data ghcr.io/ajeskey/blackcandystore:latest
```

### Use PostgreSQL As Database

Black Candy Store uses SQLite as its database by default, because SQLite simplifies installation and is an ideal choice for a small self-hosted server. If SQLite is not enough, or you are using a cloud service like Heroku to host it, you can also use PostgreSQL.

```shell
docker run -e DB_ADAPTER=postgresql -e DB_URL=postgresql://yourdatabaseurl ghcr.io/ajeskey/blackcandystore:latest
```

### How to Persist Data

All the data that needs to persist is stored in `/rails/storage`, so you can mount this directory to the host to persist data.

```shell
mkdir storage_data

docker run -v ./storage_data:/rails/storage ghcr.io/ajeskey/blackcandystore:latest
```

### Running as an Arbitrary User

When mounting volumes, you may encounter permission issues between the host and the Docker container. To resolve this, pass the UID and GID with `--user` to match the same UID and GID as your host user.

```shell
docker run --user 2000:2000 -v ./storage_data:/rails/storage ghcr.io/ajeskey/blackcandystore:latest
```

### Logging

Black Candy Store logs to `STDOUT` by default. If you want to control the log, Docker already supports a lot of options to handle logs in the container. See: https://docs.docker.com/config/containers/logging/configure/.

### Secret Key Base

Black Candy Store uses cryptography to protect sessions and other security-sensitive data, and needs a secret value as the basis of those secrets. This value can be anything, but it should be unguessable and specific to your instance.

You can use any long random string for this. One way to generate one is with `openssl`:

```shell
openssl rand -hex 64
```

Once you have one, set it in the `SECRET_KEY_BASE` environment variable:

```shell
docker run -e SECRET_KEY_BASE=your_generated_secret ghcr.io/ajeskey/blackcandystore:latest
```

If `SECRET_KEY_BASE` is not set, a new one is generated on each startup, which will invalidate all existing sessions.

## Environment Variables

| Name                         | Default   | Description                                                                                                                                                                                                                                                                               |
| ---                          | ---       |-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| DB_URL                 |           | The URL of PostgreSQL database. You must set this environment variable if you use PostgreSQL as database.                                                                                                                                                                                 |
| CABLE_DB_URL          |           | The URL of Pub/Sub database. You must set this environment variable if you use PostgreSQL as database.                                                                                                                                                                                    |
| QUEUE_DB_URL                 |           | The URL of background job database. You must set this environment variable if you use PostgreSQL as database.                                                                                                                                                                             |
| CACHE_DB_URL                 |           | The URL of cache database. You must set this environment variable if you use PostgreSQL as database.                                                                                                                                                                                      |
| MEDIA_PATH                   |           | You can use this environment variable to set the media path, otherwise you can set the media path on the settings page.                                                                                                                                                                   |
| DB_ADAPTER             | "sqlite"  | There are two adapters supported, "sqlite" and "postgresql".                                                                                                                                                                                                                              |
| SECRET_KEY_BASE              |           | When the SECRET_KEY_BASE environment variable is not set, a new SECRET_KEY_BASE is generated every time the service starts up. This invalidates old sessions, so you can set your own SECRET_KEY_BASE environment variable to avoid it.                                                    |
| FORCE_SSL                    | false     | Force all access to the app over SSL.                                                                                                                                                                                                                                                     |
| DEMO_MODE                    | false     | Whether to enable demo mode; when demo mode is on, all users cannot access administrator privileges, even if the user is admin, and users cannot change their profile.                                                                                                                    |
| HTTP_PORT                    | 80        | The port that the server listens on inside the container. Useful when you want to run on a port other than 80.                                                                                                                                                                            |
| TLS_DOMAIN                   |           | Set to your domain (e.g. `music.example.com`) to enable built-in automatic HTTPS with Let's Encrypt certificates via Thruster. When set, the server serves HTTPS on 443 and redirects HTTP to HTTPS; certificates are provisioned and renewed automatically and cached under `/rails/storage`. Leave unset for HTTP only. Accepts a comma-separated list of domains. See [docs/https.md](docs/https.md). |
| SERVER_BASE_URL              | http://localhost:3000 | This server's public base URL. Used for cross-server library sharing: it is encoded into every invite code so a redeeming server knows how to reach this server, and it is used to build this server's catalog-nudge callback URL (`<SERVER_BASE_URL>/nudges`). Set this to your server's real public URL if you share libraries across servers. |
| CATALOG_SYNC_POLL_INTERVAL   | 15        | How often, in minutes, a redeeming server pulls catalog changes for each active shared-library connection to keep its local mirror in sync. |
| PLAYBACK_SIDECAR_URL         | http://127.0.0.1:9330 | Base URL of the optional playback sidecar that streams server-side audio to AirPlay/Chromecast devices under the `server_playback` playback mode. Defaults to a co-located sidecar on loopback. If no sidecar is running, server-side output is unavailable and the UI degrades gracefully; `client_cast` is unaffected. See [docs/playback-sidecar.md](docs/playback-sidecar.md). |
| AR_ENCRYPTION_PRIMARY_KEY    |           | Primary key for Active Record encryption, used to encrypt sensitive data at rest such as the cross-server access token stored for a shared-library connection. Set all three `AR_ENCRYPTION_*` variables in production; if unset, non-secret local development defaults are used (do not rely on these for real data). |
| AR_ENCRYPTION_DETERMINISTIC_KEY |        | Deterministic key for Active Record encryption. See `AR_ENCRYPTION_PRIMARY_KEY`. |
| AR_ENCRYPTION_KEY_DERIVATION_SALT |      | Key-derivation salt for Active Record encryption. See `AR_ENCRYPTION_PRIMARY_KEY`. |

## Development

### Requirements

- Ruby 4.0
- Node.js 20
- libvips
- FFmpeg

Make sure you have installed all those dependencies.

### Install gem dependencies

```shell
bundle install
```

### Install JavaScript dependencies

```shell
npm install
```

### Database Configuration

```shell
rails db:prepare
rails db:seed
```

### Start all services

After you've set up everything, you can run `./bin/dev` to start all the services you need to develop.
Then visit <http://localhost:3000> and use the initial admin user to log in (email: admin@admin.com, password: foobar).

### Running tests

```shell
# Running all tests
$ rails test:all

# Running lint
$ rails lint:all
```

## Integrations

Black Candy Store supports getting artist and album images from the Discogs API. You can create an API token from Discogs and set the Discogs token on the Settings page to enable it.

## Acknowledgments

Black Candy Store is an expansion of the [Black Candy](https://github.com/blackcandy-org/black_candy) project, created and maintained by [blackcandy-org](https://github.com/blackcandy-org) and its contributors.

Black Candy provides the entire foundation this work is built on — the streaming server, web player, browsing and search, playlists, and the overall design and polish. This expansion only adds multi-library management, cross-server library sharing, and automatic catalog mirroring on top of that foundation; none of it would be possible without the upstream project.

A huge thank you to the Black Candy team and community for creating and maintaining such a great music server, and for making it open source. If you enjoy Black Candy Store, please consider starring and supporting the [upstream Black Candy project](https://github.com/blackcandy-org/black_candy). Please refer to the upstream repository for its license and terms.
