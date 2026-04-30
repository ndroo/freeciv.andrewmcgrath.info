# Local-dev shortcuts. All commands run inside a Debian-bookworm container so
# the dev environment matches prod (no mac-specific date/find/etc. surprises).

IMAGE := freeciv-longturn-pytools-dev
DOCKER := docker run --rm -v $(PWD):/app -w /app $(IMAGE)

.PHONY: build test bench shell

build:
	docker build -t $(IMAGE) -f Dockerfile.dev .

test: build
	$(DOCKER) pytest -v

# Quick test run without rebuilding the image. Use after `make build`.
retest:
	$(DOCKER) pytest -v

bench: build
	$(DOCKER) python3 -m benchmarks.run

shell: build
	docker run --rm -it -v $(PWD):/app -w /app $(IMAGE) bash
