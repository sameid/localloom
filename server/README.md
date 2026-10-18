# localloom-server

A small, self-hostable server for LocalLoom recordings. The LocalLoom Mac app uploads
recordings to it, and it serves the share links. It has no dependencies beyond Node.js 22+.

The Mac app also runs this same server privately on your Mac in its "This Mac" mode, so
you only need to host it yourself if you want recordings to stay online when your Mac is
off.

## Run it

With Docker Compose:

```sh
cd server
LOCALLOOM_PUBLIC_URL=https://loom.example.com docker compose up -d
docker compose exec localloom cat /data/token   # the owner token for the Mac app
```

Or directly with Node:

```sh
LOCALLOOM_PUBLIC_URL=https://loom.example.com LOCALLOOM_DATA_DIR=/srv/localloom node src/index.js
cat /srv/localloom/token
```

Then in the Mac app open **Preferences → Destination → My server**, and enter the server
URL and the token.

## Configuration

| Variable | Default | |
| --- | --- | --- |
| `LOCALLOOM_PUBLIC_URL` | (unset) | The address viewers use, e.g. `https://loom.example.com`. Share links are built from it. If unset, links use whatever address the Mac app connects with. |
| `LOCALLOOM_DATA_DIR` | `./data` (`/data` in Docker) | Where recordings and the token are stored. |
| `LOCALLOOM_PORT` | `8080` | `0` picks a free port. |
| `LOCALLOOM_HOST` | `0.0.0.0` | |
| `LOCALLOOM_TOKEN` | (generated) | The owner token. If unset, one is generated on first start and saved to `<data dir>/token`. |

The server keeps recordings until you delete them. Each recording is a folder under
`<data dir>/recordings/` with the video and a `meta.json`, so backing up the data
directory is enough.

## Putting it on the internet

The server speaks plain HTTP. Put it behind something that adds HTTPS, such as Caddy,
Traefik, nginx, Cloudflare Tunnel or Tailscale Funnel. Don't expose it over plain HTTP:
the Mac app sends the owner token with every upload.

The app uploads in 32 MB chunks, which fits under Cloudflare's 100 MB request limit.
nginx rejects bodies over 1 MB by default, so raise it:

```nginx
client_max_body_size 64m;
proxy_request_buffering off;
```

If your server has no public address (for example behind CGNAT), the compose file has an
optional ngrok sidecar:

```sh
NGROK_AUTHTOKEN=... NGROK_DOMAIN=you.ngrok-free.app \
LOCALLOOM_PUBLIC_URL=https://you.ngrok-free.app \
docker compose --profile ngrok up -d
```

ngrok's free plan shows viewers a warning page and caps monthly bandwidth, which video
uses up quickly.

## Access model

One server has one owner. Anyone with the owner token can upload, list and delete. Viewing
needs only the share link, so treat links like unlisted URLs. New recording IDs are 128-bit
random. The home page never lists or redirects to recordings.

## API

All `/api` routes need `Authorization: Bearer <token>`.

| Route | |
| --- | --- |
| `POST /api/recordings` | Body `{ "size": bytes, "duration": seconds, "id"?: string }`. Returns the recording, including `share_url`. Retrying with the same `id` and `size` returns the existing recording. |
| `PUT /api/recordings/:id/content` | Appends a chunk. Send the current offset in `Upload-Offset`. Returns `{ "offset" }`. A wrong offset returns 409 with the real `offset`, so an interrupted upload can resume. |
| `POST /api/recordings/:id/complete` | Marks the upload finished once all bytes have arrived. |
| `GET /api/recordings`, `GET /api/recordings/:id` | List or fetch recordings. |
| `DELETE /api/recordings/:id` | Delete a recording. |
| `GET /api/status` | Checks that the token works. |

Public routes: `/v/:id` (player page), `/media/:id.mp4` (video, supports range requests),
`/healthz`.

## Tests

```sh
npm test
```
