# How to Provision Players and Start the Game

## Overview

There are 3 things to do when you're ready to start:
1. Add players to the auth database (so they can log in)
2. Add players to the server config (so they get assigned nations)
3. Deploy

## Step 1: Update the Player List

Copy `players.conf.sample` to `players.conf` and add your players:

```bash
PLAYERS=(
  "player1:pass123:player1@example.com:Australian"
  "player2:pass456:player2@example.com:Canadian"
  "player3:pass789:player3@example.com:American"
  # ... add one line per player
)
```

Format: `"username:password:email:nation"`

- **username** — what they type to log in (keep short, no spaces)
- **password** — their initial password (they can't change it themselves)
- **email** — for welcome email and turn notifications
- **nation** — must be unique per player, lowercase (e.g. `australian`, `canadian`, `american`)

## Step 2: Create Auth Accounts

Run from your local machine (requires `fly` CLI):

```bash
./manage_players.sh create-all
```

This will:
- Create each player in the SQLite database on the server (via `fly ssh console`)
- Send each player a welcome email with login details and install instructions

To add a single player later:
```bash
./manage_players.sh create <username> <password> <email>
```

To verify players were created:
```bash
./manage_players.sh list
```

## Step 3: Update the Server Config

Edit `longturn.serv` and add `create` + `playernation` lines for each player:

```
# Create players and assign nations
create andrew
playernation andrew Australian 1

create jess
playernation jess Canadian 1

create bob
playernation bob American 1

# Must be 0 so server doesn't wait for min players
set minplayers 0

# Start the game
start
```

The `1` after the nation is the leader style (just use `1`).

## Step 4: Update start.sh (aitoggle)

Edit `start.sh` and uncomment/add `aitoggle` commands for each player. These switch the pre-created AI players to human control:

```bash
# When game is running, aitoggle commands for each player:
echo "aitoggle andrew" >&3
sleep 1
echo "aitoggle jess" >&3
sleep 1
echo "aitoggle bob" >&3
sleep 1
```

## Step 5: Deploy

```bash
fly deploy
```

The server will start, create the players with their assigned nations, and begin the game. Players can connect immediately.

---

## Adding Players Mid-Game

**Yes, you can add players mid-game.** Here's how:

### 1. Add their auth account
```bash
./manage_players.sh create <username> <password> <email>
```

### 2. Send a command to the running server via the FIFO
```bash
fly ssh console --app freeciv-longturn -C "bash -c 'echo \"create newplayer\" > /tmp/server-input; sleep 1; echo \"set nationset all\" > /tmp/server-input'"
```

Or more practically, you can exec into the server and write to the FIFO:
```bash
fly ssh console --app freeciv-longturn
# Then inside the server:
echo "create newplayer" > /tmp/server-input
sleep 1
echo "playernation newplayer French 1" > /tmp/server-input
sleep 1
echo "aitoggle newplayer" > /tmp/server-input
```

### 3. Update longturn.serv and start.sh for next deploy
Add the new player's `create`/`playernation` lines to `longturn.serv` and `aitoggle` to `start.sh` so they persist across restarts.

**Note:** Mid-game players start from scratch (no cities, no techs) while others may be several turns ahead. This is a significant disadvantage, so it's best to add players early.

---

## Useful Commands

| Task | Command |
|------|---------|
| List all players | `./manage_players.sh list` |
| Reset all players | `./manage_players.sh reset` |
| Check server log | `fly ssh console --app freeciv-longturn -C "tail -50 /data/saves/server.log"` |
| Check save files | `fly ssh console --app freeciv-longturn -C "ls -la /data/saves/lt-game-*.sav.gz"` |
| Restart server | `fly apps restart freeciv-longturn` |

## Nation List

Each player must pick a **unique** nation. There are 580+ nations available. To see the full list:
```bash
fly ssh console --app freeciv-longturn -C "ls /usr/local/share/freeciv/civ2civ3/nation/"
```

Common ones: American, Australian, British, Canadian, Chinese, Egyptian, French, German, Greek, Indian, Italian, Japanese, Korean, Mexican, Russian, Spanish, etc.
