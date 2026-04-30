# Top-level dev shortcuts. Most local work happens via this Makefile so we
# don't have to memorise long fly/docker invocations.
#
# Common workflows:
#   make test                  -- run all bash + python tests
#   make gazette-local TURN=54 -- preview a chronicle locally without sending
#                                 emails or hitting prod
#
# `gazette-local` requires local-data/ to be populated. See `make pull-prod`.

FLY_APP   := freeciv-longturn
LOCAL_DIR := local-data
DEV_IMAGE := freeciv-longturn-pytools-dev

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
.PHONY: test test-python test-bash

test: test-python test-bash

test-python:
	cd python && $(MAKE) test

test-bash:
	bash test_diplomacy_classify.sh
	bash test_turn_notify.sh
	bash test_generate_status.sh

# ---------------------------------------------------------------------------
# Pulling prod data into local-data/ for local experiments. These are opt-in;
# nothing automatic syncs prod data to your laptop.
# ---------------------------------------------------------------------------
.PHONY: pull-prod pull-saves pull-jsons pull-gazette-archive pull-keys

pull-prod: pull-saves pull-jsons pull-gazette-archive pull-keys
	@echo "[pull-prod] $(LOCAL_DIR) is now ready for local experiments."

pull-saves:
	@mkdir -p $(LOCAL_DIR)
	@echo "[pull-saves] Tarring saves on prod and downloading..."
	fly ssh console --app $(FLY_APP) -C "sh -c 'cd /data/saves && tar c lt-game-*.sav.gz'" \
	  > $(LOCAL_DIR)/saves.tar
	@cd $(LOCAL_DIR) && tar xf saves.tar && rm saves.tar
	@echo "[pull-saves] Pulled $$(ls $(LOCAL_DIR)/lt-game-*.sav.gz | wc -l) saves."

pull-jsons:
	@mkdir -p $(LOCAL_DIR)
	@for f in history.json diplomacy.json gazette.json attendance.json status.json; do \
	  echo "[pull-jsons] $$f"; \
	  fly ssh sftp get --app $(FLY_APP) /data/saves/$$f $(LOCAL_DIR)/$$f 2>/dev/null \
	    || echo "  (skipped — not present on prod)"; \
	done

# Pulls every gazette-*.png illustration so the local renderer can flip
# through the full back catalog (v0/v1 history) without referencing
# missing images.
pull-gazette-archive:
	@mkdir -p $(LOCAL_DIR)
	@echo "[pull-gazette-archive] Tarring gazette PNGs on prod..."
	fly ssh console --app $(FLY_APP) -C "sh -c 'cd /data/saves && tar c gazette-*.png 2>/dev/null'" \
	  > $(LOCAL_DIR)/gazette-pngs.tar
	@cd $(LOCAL_DIR) && tar xf gazette-pngs.tar && rm gazette-pngs.tar
	@echo "[pull-gazette-archive] Pulled $$(ls $(LOCAL_DIR)/gazette-*.png 2>/dev/null | wc -l) illustrations."

# Sensitive — only pull if you actually need to invoke the LLM/Gemini APIs
# locally. The keys end up in $(LOCAL_DIR) which is gitignored.
pull-keys:
	@mkdir -p $(LOCAL_DIR)
	@echo "[pull-keys] WARNING: API keys will land in $(LOCAL_DIR)/. They are gitignored, but treat them as secrets."
	@for f in anthropic_api_key openai_api_key gemini_api_key gazette_provider; do \
	  fly ssh sftp get --app $(FLY_APP) /data/saves/$$f $(LOCAL_DIR)/$$f 2>/dev/null \
	    && echo "  pulled $$f" \
	    || echo "  (skipped — $$f not present on prod)"; \
	done

# ---------------------------------------------------------------------------
# Run a chronicle generation locally against local-data/. No emails will be
# sent: generate_gazette.sh doesn't send any (turn_notify.sh does, and we're
# not invoking it). We also force email_enabled.settings=false as belt-and-
# suspenders so any accidental invocation of turn_notify would also be a
# no-op.
#
# Usage:  make gazette-local TURN=54
#                                ^ the turn whose edition to write (the
#                                  builder reports ON the previous turn)
# ---------------------------------------------------------------------------
.PHONY: gazette-local
gazette-local: dev-image
	@if [ -z "$(TURN)" ]; then \
	  echo "Usage: make gazette-local TURN=<n>"; exit 1; \
	fi
	@if [ ! -f $(LOCAL_DIR)/history.json ]; then \
	  echo "Missing $(LOCAL_DIR)/history.json — run \`make pull-prod\` first"; exit 1; \
	fi
	@if [ ! -f $(LOCAL_DIR)/anthropic_api_key ] && [ ! -f $(LOCAL_DIR)/openai_api_key ]; then \
	  echo "Missing API key in $(LOCAL_DIR)/ — run \`make pull-keys\` first"; exit 1; \
	fi
	@mkdir -p $(LOCAL_DIR)
	@echo "false" > $(LOCAL_DIR)/email_enabled.settings
	@year=$$(jq -r ".[] | select(.turn == ($(TURN) - 1)) | .year" $(LOCAL_DIR)/history.json | head -1); \
	  echo "[gazette-local] Generating chronicle for turn $$(($(TURN) - 1)) (year=$$year, no emails)"; \
	  docker run --rm \
	    -v $$(pwd):/repo \
	    -v $$(pwd)/$(LOCAL_DIR):/data/saves \
	    -w /repo \
	    -e SAVE_DIR=/data/saves \
	    -e WEBROOT=/data/saves \
	    $(DEV_IMAGE) \
	    bash -c "cp $(LOCAL_DIR)/email_enabled.settings /opt/email_enabled.settings 2>/dev/null; \
	             ./generate_gazette.sh $(TURN) $$year"
	@echo "[gazette-local] Output in $(LOCAL_DIR)/gazette.json — newest entry:"
	@jq '.[-1] | {turn, year_display, headline, illustration}' $(LOCAL_DIR)/gazette.json

dev-image:
	@docker image inspect $(DEV_IMAGE) >/dev/null 2>&1 \
	  || (cd python && docker build -t $(DEV_IMAGE) -f Dockerfile.dev .)

# ---------------------------------------------------------------------------
# Local preview server. Serves www/ overlaid with local-data/ so the page
# fetches /status.json, /gazette.json, /gazette-N.png etc. from the data
# you pulled with `make pull-prod`.
#
# The overlay is built fresh into a tempdir on each `make preview` run via
# symlinks, so editing files in www/ is picked up by the browser on
# refresh, and editing JSON in local-data/ is picked up too.
#
#   make preview               (Ctrl-C to stop)
#   open http://localhost:8080
#
# In a second terminal you can run `make regenerate-latest` to produce a
# fresh v2 chronicle without leaving the preview running.
# ---------------------------------------------------------------------------
.PHONY: preview regenerate-latest

preview:
	@if [ ! -d $(LOCAL_DIR) ]; then \
	  echo "Missing $(LOCAL_DIR)/ — run \`make pull-prod\` first"; exit 1; \
	fi
	@if [ ! -f $(LOCAL_DIR)/status.json ]; then \
	  echo "Missing $(LOCAL_DIR)/status.json — run \`make pull-jsons\` first"; exit 1; \
	fi
	@echo "[preview] Serving www/ overlaid with $(LOCAL_DIR)/ on http://localhost:8080"
	@echo "[preview] Ctrl-C to stop."
	@docker run --rm --init \
	  -v $$(pwd)/www:/srv/www:ro \
	  -v $$(pwd)/$(LOCAL_DIR):/srv/local:ro \
	  -v $$(pwd)/python/bin/preview_server.py:/srv/preview_server.py:ro \
	  -p 8080:8080 \
	  -w /srv \
	  $(DEV_IMAGE) \
	  python3 /srv/preview_server.py

# Regenerate the latest gazette edition into local-data/ for live preview.
# Reads current turn from local-data/status.json and runs generate_gazette.sh
# inside the dev container against local-data as SAVE_DIR.
regenerate-latest: dev-image
	@if [ ! -f $(LOCAL_DIR)/status.json ]; then \
	  echo "Missing $(LOCAL_DIR)/status.json — run \`make pull-prod\` first"; exit 1; \
	fi
	@if [ ! -f $(LOCAL_DIR)/anthropic_api_key ] && [ ! -f $(LOCAL_DIR)/openai_api_key ]; then \
	  echo "Missing API key in $(LOCAL_DIR)/ — run \`make pull-keys\` first"; exit 1; \
	fi
	@turn=$$(jq -r '.game.turn' $(LOCAL_DIR)/status.json); \
	  year=$$(jq -r '.game.year' $(LOCAL_DIR)/status.json); \
	  echo "[regenerate-latest] Generating chronicle for turn $$((turn - 1)) (year=$$year, no emails)"; \
	  echo "false" > $(LOCAL_DIR)/email_enabled.settings; \
	  docker run --rm \
	    -v $$(pwd):/repo \
	    -v $$(pwd)/$(LOCAL_DIR):/data/saves \
	    -w /repo \
	    -e SAVE_DIR=/data/saves \
	    -e WEBROOT=/tmp/webroot \
	    $(DEV_IMAGE) \
	    bash -c "mkdir -p /tmp/webroot && bash ./generate_gazette.sh $$turn $$year"
	@echo "[regenerate-latest] Refresh http://localhost:8080 to see it."
	@jq '.[-1] | {turn, year_display, headline}' $(LOCAL_DIR)/gazette.json
