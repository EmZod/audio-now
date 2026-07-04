PREFIX ?= $(HOME)/.local
# Engine venv: defaults to a sibling vibevoice-mlx checkout; override with
# `make install VENV_PYTHON=/path/to/python`.
VENV_PYTHON ?= $(abspath ../vibevoice-mlx/.venv/bin/python)
CONFIG := $(HOME)/.audio-now/config.json
ENGINE_DIR := $(abspath ../vibevoice-mlx)
ENGINE_REPO ?= https://github.com/EmZod/vibevoice-mlx
MODEL_DIR := $(HOME)/.audio-now/model

.PHONY: build test install clean engine setup

# One command from bare clone to speech: engine + model + daemon + CLI.
setup: engine install
	@echo 'ready — try: audio say "hello"'

engine:
	@command -v uv >/dev/null || { \
		echo "uv not found — install it first: brew install uv"; exit 2; }
	@if [ ! -d "$(ENGINE_DIR)" ]; then \
		echo 'cloning engine -> $(ENGINE_DIR)'; \
		git clone $(ENGINE_REPO) "$(ENGINE_DIR)"; \
	fi
	cd "$(ENGINE_DIR)" && uv sync
	@if [ ! -f "$(MODEL_DIR)/snapshot_meta.json" ]; then \
		echo "exporting quantized model snapshot (one-time; downloads the"; \
		echo 'fp16 weights from Hugging Face, writes ~5.4GB to $(MODEL_DIR))'; \
		cd "$(ENGINE_DIR)" && uv run python -m vibevoice_mlx.export_snapshot; \
	else \
		echo "model snapshot present — skipping export"; \
	fi

build:
	swift build -c release

test:
	swift build
	.build/debug/coretests

install: build
	mkdir -p $(PREFIX)/bin $(HOME)/.audio-now
	install .build/release/audio $(PREFIX)/bin/audio
	@if [ ! -f $(CONFIG) ]; then \
		printf '{\n  "pythonPath": "%s",\n  "workerModule": "vibevoice_mlx.worker",\n  "modelDir": "%s/.audio-now/model",\n  "voicesDir": "%s/.audio-now/voices",\n  "outDir": "%s/.audio-now/out",\n  "idleTimeoutS": 3600,\n  "wavFormat": "s16"\n}\n' \
			"$(subst \ , ,$(VENV_PYTHON))" "$(HOME)" "$(HOME)" "$(HOME)" > $(CONFIG); \
		echo "wrote $(CONFIG)"; \
	fi
	@echo "installed $(PREFIX)/bin/audio — try: audio status"

clean:
	swift package clean
