PREFIX ?= $(HOME)/.local
# Engine venv: defaults to a sibling vibevoice-mlx checkout; override with
# `make install VENV_PYTHON=/path/to/python`.
VENV_PYTHON ?= $(abspath ../vibevoice-mlx/.venv/bin/python)
CONFIG := $(HOME)/.audio-now/config.json

.PHONY: build test install clean

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
