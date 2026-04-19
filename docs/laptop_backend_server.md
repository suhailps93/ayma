# Run Ayma From This Laptop As The Backend Server

This is the minimal path to use this laptop as the backend for remote Flutter
clients, with reliable start/stop/status/logging commands.

It is workable for early testing, but it is still a single laptop:

- if the laptop sleeps, the backend disappears
- if the network changes, clients lose connectivity
- if the public URL changes, you must rebuild or reconfigure clients
- there is no load balancing, failover, or durable job queue

For now, the right shape is:

1. keep the FastAPI backend running continuously on the laptop
2. put a public HTTPS/WSS tunnel in front of it
3. point Flutter clients at that public base URL

## 1. Important constraints

### Use HTTPS and WSS for real devices

The Flutter app currently talks to the backend over both HTTP and WebSocket.
For users outside your LAN, use a public `https://...` URL and `wss://...`
WebSocket traffic through a tunnel or reverse proxy.

Do **not** rely on plain `http://` or `ws://` for distributed client builds.
That is fragile on mobile and typically blocked by platform network policies.

### Keep the laptop awake

Disable sleep and lid-suspend for the period you want this to act as a server.
If the machine sleeps, all users disconnect.

### Protect secrets

This repo uses live backend credentials from `.env`. Treat that file as
sensitive. Do not ship it, upload it, or expose it through any static hosting.

## 2. Verify the backend locally

From the repo root:

```bash
cd /home/suhailps/latest_claude/ayma
./ops/run_backend_server.sh
```

That script loads `.env` and starts:

```text
http://127.0.0.1:8000
ws://127.0.0.1:8000/ws
```

If you want LAN access instead of a localhost-only bind:

```bash
AYMA_BACKEND_HOST=0.0.0.0 ./ops/run_backend_server.sh
```

## 3. Keep it running continuously with systemd user services

Install the services:

```bash
cd /home/suhailps/latest_claude/ayma
chmod +x ops/run_backend_server.sh ops/run_public_tunnel.sh ops/ayma-server
./ops/ayma-server install
systemctl --user enable --now ayma-backend.service
loginctl enable-linger "$USER"
```

Useful commands:

```bash
./ops/ayma-server start
./ops/ayma-server stop
./ops/ayma-server restart
./ops/ayma-server status
./ops/ayma-server logs
```

`loginctl enable-linger` matters if you want the service to survive after you
log out.

### Tunnel control commands

```bash
./ops/ayma-server tunnel-start
./ops/ayma-server tunnel-stop
./ops/ayma-server tunnel-restart
./ops/ayma-server tunnel-status
./ops/ayma-server tunnel-logs
./ops/ayma-server public-url
```

### Raw systemd commands

```bash
systemctl --user status ayma-backend.service
systemctl --user status ayma-tunnel.service
journalctl --user -u ayma-backend.service -n 200 -f
journalctl --user -u ayma-tunnel.service -n 200 -f
```

## 4. Expose it to the world

You need a public HTTPS endpoint that forwards to `http://127.0.0.1:8000`.

Two practical options:

### Option A: Cloudflare Tunnel

Best when you want a stable hostname like `api.example.com` without opening
router ports directly.

This repo supports two tunnel modes:

- quick tunnel: works immediately, public URL changes on restart
- named tunnel: stable hostname, requires `CLOUDFLARED_TUNNEL_TOKEN`

Quick tunnel example:

```bash
./ops/run_public_tunnel.sh
```

Named tunnel example:

```bash
cp /home/suhailps/latest_claude/ayma/ops/examples/tunnel.env.example ~/.config/ayma/tunnel.env
printf 'CLOUDFLARED_TUNNEL_TOKEN=...\\n' >> ~/.config/ayma/tunnel.env
./ops/run_public_tunnel.sh
```

If `CLOUDFLARED_TUNNEL_TOKEN` is set, the script runs the named tunnel. If it is
not set, it falls back to a quick tunnel and logs the temporary URL.

Optional backend overrides can go in:

```bash
cp /home/suhailps/latest_claude/ayma/ops/examples/backend.env.example ~/.config/ayma/backend.env
```

### Option B: ngrok

Best when you want the fastest setup and are okay using ngrok-managed domains or
a reserved domain on a paid plan.

Example shape:

```bash
ngrok http http://127.0.0.1:8000
```

Again, use a stable reserved domain if you want remote clients to keep working.

## 5. Point Flutter clients at the public backend

The Flutter app now supports a single base URL define:

```bash
--dart-define=AYMA_PUBLIC_BASE_URL=https://your-public-hostname
```

That one value drives:

- HTTP requests to `https://your-public-hostname`
- WebSocket connections to `wss://your-public-hostname/ws`

Examples:

```bash
cd /home/suhailps/latest_claude/ayma/ayma_flutter
flutter run --dart-define=AYMA_PUBLIC_BASE_URL=https://api.example.com
```

```bash
flutter build apk --release \
  --dart-define=AYMA_PUBLIC_BASE_URL=https://api.example.com
```

If you need separate values, the old overrides still work:

- `AYMA_HTTP_BASE_URL`
- `AYMA_WS_URL`

## 6. Router and firewall notes

If you use a tunnel, you usually do **not** need to open inbound router ports.
If you expose the laptop directly instead:

- reserve a static LAN IP for the laptop
- forward TCP 443 from the router to the reverse proxy on the laptop
- terminate TLS on the laptop with a real certificate
- avoid exposing raw Uvicorn directly to the internet

For a laptop-first setup, a tunnel is the simpler and safer path.

## 7. Backend behavior in this laptop-hosted mode

This project already supports direct in-process background work when
`CLOUD_TASKS_QUEUE` is empty. That means laptop-hosted mode can still do:

- auth
- onboarding
- text chat
- live WebSocket chat
- media upload and processing
- match generation

without provisioning Cloud Tasks first.

## 8. Recommended first rollout

If the goal is to get remote users working quickly:

1. run the backend as a user service on this laptop
2. start a quick tunnel immediately to validate remote connectivity
3. switch to a named Cloudflare tunnel once you have `CLOUDFLARED_TUNNEL_TOKEN`
4. rebuild the Flutter app with `AYMA_PUBLIC_BASE_URL=https://that-host`
5. test login, `/api/chat/text`, `/ws`, media upload, and onboarding from a device not on your LAN

## 9. Logging and troubleshooting

The backend and tunnel both log to the user systemd journal.

Backend logs:

```bash
./ops/ayma-server logs
```

Tunnel logs:

```bash
./ops/ayma-server tunnel-logs
```

Current quick-tunnel public URL:

```bash
./ops/ayma-server public-url
```

Common checks:

- backend not starting: run `./ops/ayma-server status` and inspect `.env`
- tunnel not starting: confirm `~/.local/bin/cloudflared` exists and is executable
- quick tunnel URL needed again: run `./ops/ayma-server tunnel-logs` and find the public `trycloudflare.com` URL
- named tunnel unstable: verify `CLOUDFLARED_TUNNEL_TOKEN` is exported into the service environment before start
- clients cannot connect: verify the app was built with `AYMA_PUBLIC_BASE_URL=https://...`

## 10. Risks you should expect

- laptop sleep or reboot drops all sessions
- tunnel disconnects break all clients immediately
- home/office ISP instability becomes app instability
- upload throughput and live voice quality depend on this laptop's network
- there is no horizontal scaling

This is acceptable for an early private alpha. It is not a durable production
shape.
