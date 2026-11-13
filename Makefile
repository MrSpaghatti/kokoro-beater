# kokoro-beater -- build handle.
#
# Everything a stranger needs to go from a checkout to a working binary.
# The binary MUST be built into bin/: espeak.nim and onnx.nim resolve the
# vendored .so files relative to the executable's own directory (bin/ and its
# parent), so a binary built somewhere else dies asking for KOKORO_*_LIB.

NIM        ?= nim
NIMFLAGS   ?= -d:release --mm:arc --hints:off
SRC        := src/kbcli.nim
BIN        := bin/kokoro-beater
SOURCE_SRCS:= $(wildcard src/*.nim) $(wildcard src/*.json) $(wildcard src/*.txt)

# Where the model assets come from when you have them locally. Override with
#   make models MODELS_SRC=/path/to/models
MODELS_SRC ?= $(HOME)/Downloads/audiobook/models
MODELS     := models

# t_espeak is a debug harness (prints, never asserts) -- it is not part of the
# pass/fail suite; run it explicitly with `make test-espeak`.
TESTS := $(filter-out tests/t_espeak.nim,$(wildcard tests/t_*.nim))

.PHONY: all build models test test-espeak selfcheck blind-check clean

all: build

build: $(BIN)

$(BIN): $(SRC) $(SOURCE_SRCS)
	@mkdir -p bin
	$(NIM) c $(NIMFLAGS) -o:$(BIN) $(SRC)

## Fetch/link the ONNX model + voices into ./models (gitignored, never committed).
models:
	@mkdir -p $(MODELS)
	@for f in kokoro-v1.0.onnx voices-v1.0.bin; do \
		if [ -f "$(MODELS_SRC)/$$f" ]; then \
			cp -f "$(MODELS_SRC)/$$f" $(MODELS)/; \
		else \
			echo "ERROR: $(MODELS_SRC)/$$f not found (set MODELS_SRC=)"; exit 1; \
		fi; \
	done
	@ls -lh $(MODELS)

## Compile and run every assertion-bearing test; nonzero exit if any fails.
test: build
	@pass=0; fail=0; failed=""; \
	for t in $(TESTS); do \
		n=$$(basename $$t .nim); \
		if $(NIM) c --path:src --hints:off -o:tests/$$n $$t >/tmp/kb-$$n.build 2>&1 \
		   && ./tests/$$n >/tmp/kb-$$n.out 2>&1; then \
			echo "PASS  $$n"; pass=$$((pass+1)); \
		else \
			echo "FAIL  $$n  (logs: /tmp/kb-$$n.build /tmp/kb-$$n.out)"; \
			fail=$$((fail+1)); failed="$$failed $$n"; \
		fi; \
	done; \
	echo "---"; echo "$$pass passed, $$fail failed"; \
	if [ $$fail -ne 0 ]; then echo "FAILED:$$failed"; exit 1; fi

test-espeak:
	$(NIM) c -r --path:src --hints:off tests/t_espeak.nim

## Synthetic end-to-end check: synth a fixed sentence, read the WAV back,
## assert header/rate/duration/peak. Needs ./models (make models).
selfcheck: build
	./$(BIN) --selfcheck

## Proof the selfcheck can fail: blind the peak requirement, expect nonzero exit.
blind-check: build
	@if KOKORO_SELFCHECK_BLIND=1 ./$(BIN) --selfcheck; then \
		echo "BLIND CHECK DID NOT FAIL -- the selfcheck is decoration"; exit 1; \
	else \
		echo "blind-check OK: selfcheck fails when blinded, as it must"; \
	fi

clean:
	rm -rf bin nimcache tests/t_emotions tests/t_g2p tests/t_profile \
		tests/t_vocab tests/t_voiceforge tests/t_espeak