# Freeciv Longturn Server

A self-hosted Freeciv 3.2.3 multiplayer server designed for longturn games (23-hour turns), running on Fly.io with email notifications, a live status page, and an AI-generated newspaper.

## What is Longturn?

Longturn is a style of Freeciv multiplayer where each turn lasts ~23 hours instead of minutes. Players log in once a day, make their moves, click "Turn Done", and go about their lives. When all players have ended their turn (or the timer runs out), the next turn begins.

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│  Fly.io Container                               │
│                                                  │
│  entrypoint.sh                                   │
│    ├── busybox crond (status page refresh)       │
│    └── start.sh                                  │
│         ├── freeciv-server (port 5556)           │
│         ├── busybox httpd (port 8080 → 80/443)  │
│         ├── FIFO command writer                  │
│         ├── Turn change watcher                  │
│         ├── Auto-saver (every 5 min)             │
│         └── Turn reminder checker                │
│                                                  │
│  /data/saves (persistent volume)                 │
│    ├── lt-game-*.sav.gz    (save files)          │
│    ├── freeciv.sqlite       (player auth DB)     │
│    ├── status.json          (live game state)    │
│    ├── history.json         (per-turn stats)     │
│    ├── attendance.json      (missed turns)       │
│    ├── diplomacy.json       (relationships)      │
│    └── gazette.json         (AI newspaper)       │
└─────────────────────────────────────────────────┘
```

The server communicates via a FIFO pipe (`/tmp/server-input`) — scripts send commands to the running Freeciv server by writing to this pipe.

## Scripts

### Core

| Script | Purpose |
|--------|---------|
| `entrypoint.sh` | Container entrypoint. Starts crond, then drops privileges and runs `start.sh`. |
| `start.sh` | Main orchestrator. Starts the Freeciv server, FIFO pipe, auto-save, turn watcher, reminder loop, HTTP server, and handles resume logic (preserving turn timer across restarts). |
| `longturn.serv` | Game settings: 23-hour turns, 10-hour unitwaittime, allied victory only, player list. |

### Status Page

| Script | Purpose |
|--------|---------|
| `generate_status_json.sh` | Extracts game state from save files into JSON. Runs every 5 minutes via cron and on each turn change. Produces `status.json`, `history.json`, `attendance.json`, and `diplomacy.json`. |
| `www/index.html` | Client-side status page. Fetches JSON and renders rankings, charts (Chart.js), diplomacy, countdown timer, and gazette articles. |
| `www/cgi-bin/health` | Healthcheck endpoint. Returns 503 if `status.json` is stale (>7 min), used by uptime monitors. |

### Notifications

| Script | Purpose |
|--------|---------|
| `turn_notify.sh` | Sends HTML email to all players when a new turn starts. Includes rankings table, gazette, and deadline. |
| `turn_reminder.sh` | Runs every 60 seconds. If within 2 hours of the deadline, sends a nudge email to players who haven't clicked "Turn Done". |
| `turn_notify.lua` | Freeciv signal handler that triggers `turn_notify.sh` on turn change. |

### Player Management

| Script | Purpose |
|--------|---------|
| `manage_players.sh` | Create player accounts in the SQLite auth DB, send welcome emails, list players. |
| `fcdb.conf` / `database.lua` | SQLite auth database configuration and initialization. |

### Utilities

| Script | Purpose |
|--------|---------|
| `fix_turn_timer.sh` | Override the turn deadline to a specific clock time (e.g., `./fix_turn_timer.sh 4` for 4 AM). Restores normal 23hr timeout on the next turn. |
| `change_gold.sh` | Adjust a player's gold via Lua command (e.g., `./change_gold.sh andrew 50`). |
| `generate_gazette.sh` | Calls OpenAI to generate "The Civ Chronicle" — an era-appropriate, unreliable wartime newspaper article for each turn. |
| `generate_nations.sh` | Generates a static HTML page listing all available nations. |
| `local_preview.sh` | Preview the status page locally using save file data. |

### Config Files

| File | Purpose |
|------|---------|
| `email_enabled.settings` | Set to `true` or `false` to toggle all email notifications. |
| `crontab` | Cron schedule — runs `generate_status_json.sh` every 5 minutes. |
| `fly.toml` | Fly.io deployment config (region, VM size, ports, volume). |
| `Dockerfile` | Multi-stage build: compiles Freeciv 3.2.3 from source, then creates a lean runtime image. |

## Setup Guide

### Prerequisites

- [Fly.io CLI](https://fly.io/docs/hands-on/install-flyctl/) (`flyctl`)
- Docker (for local builds/testing)
- An AWS account with SES configured (for email notifications)
- An OpenAI API key (optional, for the AI gazette feature)

### 1. Clone and Configure

```bash
git clone <repo-url>
cd freeciv-server
cp .env.sample .env
```

Edit `.env` with your credentials:

```
SES_SMTP_USER=your-ses-smtp-username
SES_SMTP_PASS=your-ses-smtp-password
SES_SMTP_HOST=email-smtp.us-east-1.amazonaws.com
OPENAI_API_KEY=your-openai-key  # optional, for gazette
```

### 2. Customize Game Settings

Edit `longturn.serv` to configure your game:

- `timeout 82800` — Turn length in seconds (82800 = 23 hours)
- `unitwaittime 36000` — Prevents double-moves (36000 = 10 hours)
- `victories ALLIED` — Victory conditions
- Player list (`create` commands at the bottom)

Update email settings in the notification scripts:

- `FROM_EMAIL` — The sender address (must be verified in SES)
- `SERVER_HOST` — Your server's hostname
- `CC_EMAIL` — Optional CC address for all emails

### 3. Add Players

Copy the sample players file and add your players:

```bash
cp players.conf.sample players.conf
```

Edit `players.conf` with one line per player:

```bash
PLAYERS=(
  "player1:pass123:player1@example.com:Australian"
  "player2:pass456:player2@example.com:Canadian"
  # ... add one line per player
)
```

Format: `"username:password:email:nation"`. This file is gitignored — credentials stay local.

You'll also need to add matching `create` commands in `longturn.serv` and aitoggle entries in `start.sh` for each player. See `HOWTO-PROVISION-PLAYERS.md` for the full walkthrough.

### 4. Deploy to Fly.io

```bash
# Create the app
fly launch --name your-app-name

# Create a persistent volume for saves
fly volumes create freeciv_saves --size 1 --region your-region

# Set secrets (instead of hardcoding in scripts)
fly secrets set \
  SES_SMTP_USER=your-ses-smtp-username \
  SES_SMTP_PASS=your-ses-smtp-password \
  OPENAI_API_KEY=your-openai-key

# Deploy
fly deploy
```

### 5. Create Player Accounts

Once deployed, provision all player accounts from your `players.conf`:

```bash
# Create all accounts and send welcome emails
./manage_players.sh create-all

# Or add a single player
./manage_players.sh create username password email@example.com
```

This creates entries in the SQLite auth database and sends each player a welcome email with connection instructions.

### 6. Share Connection Details

Players connect using the Freeciv 3.2.3 client:

- **Host**: your-app-name.fly.dev
- **Port**: 5556
- **Username/Password**: as created above

The status page is available at `https://your-app-name.fly.dev`.

## Common Operations

```bash
# Deploy changes
fly deploy

# SSH into the container
fly ssh console --app your-app-name

# Force a save
fly ssh console --app your-app-name -C "sh -c 'echo save > /tmp/server-input'"

# Regenerate the status page
fly ssh console --app your-app-name -C "/opt/freeciv/generate_status_json.sh"

# Check server logs
fly ssh console --app your-app-name -C "tail -50 /data/saves/server.log"

# Override turn deadline to 4 AM
./fix_turn_timer.sh 4

# Change a player's gold
./change_gold.sh playername 100

# Toggle emails off
# Edit email_enabled.settings to "false" and redeploy

# Restart the server (preserves turn timer)
fly apps restart your-app-name
```

## Modifying Game State

The most reliable way to change game state mid-game is editing the save file directly. FIFO commands get garbled beyond ~200 characters, and many server commands are blocked mid-game.

```bash
# 1. Force a save
fly ssh console --app your-app-name -C "sh -c 'echo save > /tmp/server-input; sleep 3'"

# 2. Download it
fly ssh console --app your-app-name -C "cat /data/saves/save-latest.sav.gz" > /tmp/save.sav.gz
gzip -dc /tmp/save.sav.gz > /tmp/save.txt

# 3. Edit /tmp/save.txt (it's plaintext INI-style)

# 4. Upload and restart
gzip -c /tmp/save.txt > /tmp/save-edited.sav.gz
cat /tmp/save-edited.sav.gz | base64 | fly ssh console --app your-app-name \
  -C "sh -c 'base64 -d > /data/saves/save-latest.sav.gz'"
fly apps restart your-app-name
```

## Reboot Resilience

The server preserves the turn timer across restarts and redeploys. On resume, `start.sh`:

1. Reads `phase_seconds` (time elapsed in the current turn) from the save file
2. Calculates remaining time: `timeout - phase_seconds`
3. Restores the correct deadline so players don't lose time

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SES_SMTP_USER` | For emails | — | AWS SES SMTP username |
| `SES_SMTP_PASS` | For emails | — | AWS SES SMTP password |
| `SES_SMTP_HOST` | No | `email-smtp.us-east-1.amazonaws.com` | SES SMTP endpoint |
| `OPENAI_API_KEY` | For gazette | — | OpenAI API key for AI newspaper |
| `SERVER_HOST` | No | `freeciv.andrewmcgrath.info` | Server hostname (for emails/status page) |
| `FROM_EMAIL` | No | `freeciv@andrewmcgrath.info` | Sender email address |

Set these as Fly.io secrets for production:

```bash
fly secrets set SES_SMTP_USER=... SES_SMTP_PASS=... OPENAI_API_KEY=...
```

## Project Structure

```
├── Dockerfile                  # Multi-stage build (compile Freeciv + runtime)
├── fly.toml                    # Fly.io config
├── entrypoint.sh               # Container entrypoint
├── start.sh                    # Server startup orchestrator
├── longturn.serv               # Game settings
├── fcdb.conf                   # Auth DB config
├── database.lua                # DB initialization
├── crontab                     # Scheduled tasks
├── email_enabled.settings      # Email toggle
├── turn_notify.lua             # Turn change signal handler
├── generate_status_json.sh     # Status page data pipeline
├── generate_gazette.sh         # AI newspaper generator
├── generate_nations.sh         # Nations list page
├── turn_notify.sh              # Turn email notifications
├── turn_reminder.sh            # Deadline reminder emails
├── manage_players.sh           # Player account management
├── fix_turn_timer.sh           # Manual deadline override
├── change_gold.sh              # Gold adjustment utility
├── local_preview.sh            # Local testing helper
├── .env.sample                 # Environment variables template
├── www/
│   ├── index.html              # Status page (JS-rendered)
│   ├── changelog.html          # Game changelog
│   └── cgi-bin/
│       └── health              # Healthcheck endpoint
└── CLAUDE.md                   # Operations reference
```
