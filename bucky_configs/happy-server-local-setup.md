# Happy Server - Local Network Self-Hosting Guide (Podman)

Step-by-step instructions for running Happy Server on a local network using Podman and docker-compose, with HTTPS so the iOS/Android mobile app can connect.

## Prerequisites

- **Podman** installed (not Docker) with `podman compose` support
- A machine on your LAN with a resolvable hostname (this guide uses `bms4.lan` — replace with yours)
- The `happy` CLI installed on your workstation
- The Happy mobile app installed on your phone
- `openssl` available (for generating/inspecting certs)

## Architecture Overview

```
Phone (Happy App)  ──HTTPS──▶  Caddy (:3030) ──HTTP──▶ happy-server (:3005)
CLI (happy)        ──HTTPS──▶       │
                                    ├──▶ PostgreSQL (:5432)
                                    ├──▶ Redis (:6379)
                                    └──▶ MinIO (:9000)
```

Caddy terminates TLS with a self-signed local CA certificate. The CA cert must be trusted by both the CLI (via `NODE_EXTRA_CA_CERTS`) and the mobile device (via a manually installed profile).

---

## Step 1: Clone the Repository

```bash
git clone https://github.com/slopus/happy-server.git
cd happy-server
```

## Step 2: Fix the Dockerfile

The upstream Dockerfile's runner stage is missing the `prisma/` directory, which is needed for database migrations. Add the missing `COPY` line to the runner stage:

```dockerfile
# Stage 1: Building the application
FROM node:20 AS builder

# Install dependencies
RUN apt-get update && apt-get install -y python3 ffmpeg make g++ build-essential && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy package.json and yarn.lock
COPY package.json yarn.lock ./
COPY ./prisma ./prisma

# Install dependencies
RUN yarn install --frozen-lockfile --ignore-engines

# Copy the rest of the application code
COPY ./tsconfig.json ./tsconfig.json
COPY ./vitest.config.ts ./vitest.config.ts
COPY ./sources ./sources

# Build the application
RUN yarn build

# Stage 2: Runtime
FROM node:20 AS runner

WORKDIR /app

# Install dependencies
RUN apt-get update && apt-get install -y python3 ffmpeg && rm -rf /var/lib/apt/lists/*

# Set environment to production
ENV NODE_ENV=production

# Copy necessary files from the builder stage
COPY --from=builder /app/tsconfig.json ./tsconfig.json
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/sources ./sources
COPY --from=builder /app/prisma ./prisma

# Expose the port the app will run on
EXPOSE 3000

# Command to run the application
CMD ["yarn", "start"]
```

The critical addition is `COPY --from=builder /app/prisma ./prisma` — without it, `prisma migrate deploy` cannot find the schema and migrations at startup.

## Step 3: Build the Container Image

```bash
podman build -t happy-server:latest .
```

## Step 4: Generate a Master Secret

The server requires a `HANDY_MASTER_SECRET` environment variable for token signing and encryption. Generate a secure random value:

```bash
openssl rand -hex 32
```

Save this value — you'll use it in the docker-compose file. **Important:** if you ever change this secret, all existing auth tokens become invalid and all clients must re-authenticate.

## Step 5: Create the Caddyfile

Create a `Caddyfile` in the project root. Replace `bms4.lan` with your machine's LAN hostname:

```
your-hostname.lan {
    tls internal
    reverse_proxy happy-server:3005
}
```

`tls internal` tells Caddy to generate a self-signed certificate using its own local CA. This is required because iOS App Transport Security (ATS) blocks plain `http://` connections from apps (Safari is exempt, but the Happy app is not).

## Step 6: Create docker-compose.yml

Create `docker-compose.yml` in the project root. Replace `bms4.lan` with your hostname and paste your generated secret:

```yaml
services:
  caddy:
    image: docker.io/library/caddy:2-alpine
    restart: unless-stopped
    ports:
      - "3030:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - happy-server

  happy-server:
    image: happy-server:latest
    pull_policy: never
    restart: unless-stopped
    command: ["sh", "-c", "npx prisma migrate deploy && yarn start"]
    environment:
      - NODE_ENV=production
      - PORT=3005
      - HANDY_MASTER_SECRET=<YOUR_GENERATED_SECRET_HERE>

      # internal service DNS names (NOT localhost)
      - DATABASE_URL=postgresql://postgres:postgres@postgres:5432/happy-server
      - REDIS_URL=redis://redis:6379

      # MinIO / S3 settings
      - S3_HOST=minio
      - S3_PORT=9000
      - S3_USE_SSL=false
      - S3_ACCESS_KEY=minioadmin
      - S3_SECRET_KEY=minioadmin
      - S3_BUCKET=happy
      - S3_PUBLIC_URL=http://minio:9000/happy
    depends_on:
      postgres:
        condition: service_started
      redis:
        condition: service_started
      createbuckets:
        condition: service_completed_successfully

  postgres:
    image: docker.io/library/postgres:15
    restart: unless-stopped
    environment:
      - POSTGRES_DB=happy-server
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: docker.io/library/redis:7-alpine
    restart: unless-stopped
    volumes:
      - redis_data:/data

  minio:
    image: docker.io/minio/minio:latest
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      - MINIO_ROOT_USER=minioadmin
      - MINIO_ROOT_PASSWORD=minioadmin
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 5s
      timeout: 5s
      retries: 5
    # Optional: uncomment to access MinIO console from the browser
    # ports:
    #   - "9000:9000"
    #   - "9001:9001"

  createbuckets:
    image: docker.io/minio/mc:latest
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      mc alias set myminio http://minio:9000 minioadmin minioadmin;
      mc mb --ignore-existing myminio/happy;
      mc anonymous set download myminio/happy;
      exit 0;
      "

volumes:
  postgres_data:
  redis_data:
  minio_data:
  caddy_data:
  caddy_config:
```

### Key design decisions in this compose file

| Concern | Solution |
|---|---|
| **Missing `HANDY_MASTER_SECRET`** | The code reads `process.env.HANDY_MASTER_SECRET` (not `SEED` as the upstream docs suggest). Without it, the server crashes on startup in `initEncrypt()`. |
| **Database migrations** | `command` runs `npx prisma migrate deploy` before `yarn start`. The upstream image has no migration step, so the database would be empty. |
| **MinIO bucket creation** | The `createbuckets` init container creates the `happy` S3 bucket. Without it, `loadFiles()` fails on startup because it calls `s3client.bucketExists()`. |
| **HTTPS via Caddy** | iOS ATS blocks plain HTTP from apps. Caddy provides TLS termination with a self-signed local CA. |
| **Startup ordering** | `depends_on` with conditions ensures: MinIO is healthy before bucket creation, bucket creation completes before happy-server starts. |

## Step 7: Start the Stack

```bash
podman compose up -d
```

Wait ~15 seconds for migrations to run, then verify:

```bash
# Check all containers are stable (not restart-looping)
podman compose ps

# The happy-server container should show "Up XX seconds", not "Up Less than a second"

# Check server logs
podman logs happy-server-happy-server-1

# You should see:
#   All migrations have been successfully applied.
#   ...
#   Server listening at http://...
#   API ready on port http://localhost:3005
#   Ready

# Test HTTPS (skip cert verification for now)
curl -k https://your-hostname.lan:3030/
# Expected: Welcome to Happy Server!
```

## Step 8: Extract the Caddy Root CA Certificate

Caddy generates a local CA on first run. Extract it so you can trust it on your devices:

```bash
podman cp happy-server-caddy-1:/data/caddy/pki/authorities/local/root.crt ./caddy-root-ca.crt
```

Verify it:

```bash
openssl x509 -in caddy-root-ca.crt -noout -subject -issuer -dates
# Should show: CN=Caddy Local Authority - YYYY ECC Root
```

## Step 9: Configure the CLI

### Set environment variables

The CLI needs two things: the server URL and the CA cert for Node.js to trust the self-signed HTTPS.

**Fish shell** (`~/.config/fish/config.fish` or as universal variables):

```fish
set -Ux HAPPY_SERVER_URL https://your-hostname.lan:3030
set -Ux NODE_EXTRA_CA_CERTS /path/to/happy-server/caddy-root-ca.crt
```

**Zsh** (`~/.zshrc`):

```bash
export HAPPY_SERVER_URL="https://your-hostname.lan:3030"
export NODE_EXTRA_CA_CERTS="$HOME/happy-server/caddy-root-ca.crt"
```

**Bash** (`~/.bashrc`):

```bash
export HAPPY_SERVER_URL="https://your-hostname.lan:3030"
export NODE_EXTRA_CA_CERTS="$HOME/happy-server/caddy-root-ca.crt"
```

Open a new terminal after editing, or source the config file.

### Verify the CLI can reach the server

```bash
echo $HAPPY_SERVER_URL
# https://your-hostname.lan:3030

curl -k $HAPPY_SERVER_URL/
# Welcome to Happy Server!
```

## Step 10: Configure the Mobile App (iOS)

### 10a: Install the Caddy Root CA on iPhone

iOS App Transport Security blocks plain HTTP and rejects untrusted HTTPS certificates. You must install and trust Caddy's root CA.

1. **Transfer the cert to your phone** — AirDrop `caddy-root-ca.crt` to your iPhone, or email it to yourself and open the attachment on the phone.

2. **Install the profile** — When you open the `.crt` file, iOS will say "Profile Downloaded". Go to:
   - **Settings > General > VPN & Device Management**
   - Tap the "Caddy Local Authority" profile
   - Tap **Install** and confirm

3. **Enable full trust** — The profile is installed but not yet trusted for TLS. Go to:
   - **Settings > General > About > Certificate Trust Settings**
   - Toggle **ON** for "Caddy Local Authority"
   - Confirm the warning

### 10b: Set the server URL in the Happy app

1. Open the Happy app
2. If you're not logged in, look for a **server icon** in the header bar on the home screen
3. Tap it to open the **Server Configuration** screen
4. Enter: `https://your-hostname.lan:3030`
5. The app will validate the URL by fetching `GET /` and checking for the response "Welcome to Happy Server!"
6. Once validated, the URL is saved persistently (survives app restarts and logouts)

If you're already logged in and need to change the URL, either log out first (the server icon only appears when unauthenticated) or access it via the dev screen if available.

## Step 11: Authenticate the CLI

The auth flow requires both the CLI and the mobile app to talk to the same server.

```bash
happy logout   # clear any old tokens from a previous server
happy login    # or just run: happy
```

1. Choose **Mobile App** authentication
2. A QR code appears in the terminal
3. Scan the QR code with the Happy mobile app
4. The mobile app approves the request by calling `POST /v1/auth/response` on your server
5. The CLI detects the approval and receives a token

Verify:

```bash
happy auth status
# Should show: ✓ Authenticated
```

---

## Troubleshooting

### Server crash-loops ("Up Less than a second")

Check logs:

```bash
podman logs happy-server-happy-server-1 2>&1 | tail -30
```

| Error | Cause | Fix |
|---|---|---|
| `"password" argument must be of type string... Received undefined` | `HANDY_MASTER_SECRET` not set | Add the env var to docker-compose.yml |
| `Could not find Prisma Schema` | `prisma/` dir missing from image | Add `COPY --from=builder /app/prisma ./prisma` to Dockerfile runner stage |
| `bucketExists` error | MinIO bucket doesn't exist | Ensure the `createbuckets` init container runs before happy-server |

### CLI: "unable to get local issuer certificate"

Node.js doesn't trust Caddy's self-signed CA.

```bash
# Verify the env var is set
echo $NODE_EXTRA_CA_CERTS
# Should point to caddy-root-ca.crt

# Test with curl
curl https://your-hostname.lan:3030/
# If this fails too, the cert isn't trusted system-wide either — that's OK,
# NODE_EXTRA_CA_CERTS only needs to be set for Node.js/the CLI
```

### Mobile app: "can't connect" with http:// URL

iOS ATS blocks plain HTTP from apps. You **must** use HTTPS. This is why Caddy is in the stack.

### Mobile app: "can't connect" with https:// URL

The Caddy root CA is not trusted on the phone. Follow Step 10a carefully — both installing the profile AND enabling full trust under Certificate Trust Settings.

### CLI stuck at "Waiting for authentication..."

The mobile app's auth approval (`POST /v1/auth/response`) isn't reaching the server. This means:
- The mobile app is pointing at a different server URL — verify in the app's server settings
- The phone can't reach the server — verify `https://your-hostname.lan:3030` loads in Safari on the phone

Check server logs to confirm whether the mobile's request arrived:

```bash
podman logs happy-server-happy-server-1 2>&1 | grep "auth-response"
```

### CLI: 401 Unauthorized

The CLI has a cached token from a different server instance (different `HANDY_MASTER_SECRET` = different signing keys). Re-authenticate:

```bash
happy logout
happy login
```

---

## Resetting Everything

To start completely fresh (wipes all data):

```bash
podman compose down -v   # -v removes named volumes (database, redis, minio data)
podman build -t happy-server:latest .
podman compose up -d
```

You'll need to re-authenticate all clients after a reset.

## Port Reference

| Service | Internal Port | Exposed Port | Protocol |
|---|---|---|---|
| Caddy (HTTPS proxy) | 443 | 3030 | HTTPS |
| happy-server | 3005 | not exposed | HTTP (internal) |
| PostgreSQL | 5432 | not exposed | TCP (internal) |
| Redis | 6379 | not exposed | TCP (internal) |
| MinIO API | 9000 | not exposed | HTTP (internal) |
| MinIO Console | 9001 | not exposed | HTTP (internal) |
