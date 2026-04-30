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
.PHONY: pull-prod pull-saves pull-jsons pull-keys

pull-prod: pull-saves pull-jsons pull-keys
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
