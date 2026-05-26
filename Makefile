# redpen — keep per-plugin shared/ copies in sync with the canonical source.
#
# Why: Codex (and the Claude Code marketplace, post-Tasks 1+2 refactor) copies
# a plugin directory into its install cache. Sibling directories like
# plugins/shared/ do NOT get copied along with plugins/redpen-codex/. The
# workaround is to bundle a copy of shared/ inside EACH plugin so the install
# is self-contained.
#
# plugins/shared/ is the canonical source — edit there.
# plugins/redpen/shared/ and plugins/redpen-codex/shared/ are bundled copies.
# Run `make sync-shared` after editing the canonical source.
#
# `make check-shared` verifies the copies are in sync (use in CI).

SHARED_SRC := plugins/shared
SHARED_TARGETS := plugins/redpen/shared plugins/redpen-codex/shared
SHARED_FILES := coach_prompts.sh render_diff.py

.PHONY: sync-shared check-shared

sync-shared:
	@for target in $(SHARED_TARGETS); do \
		mkdir -p $$target; \
		for f in $(SHARED_FILES); do \
			cp -p $(SHARED_SRC)/$$f $$target/$$f; \
		done; \
	done
	@echo "synced $(SHARED_SRC)/* → $(SHARED_TARGETS)"

check-shared:
	@fail=0; \
	for target in $(SHARED_TARGETS); do \
		for f in $(SHARED_FILES); do \
			if ! cmp -s $(SHARED_SRC)/$$f $$target/$$f; then \
				echo "DRIFT: $$target/$$f differs from $(SHARED_SRC)/$$f — run 'make sync-shared'"; \
				fail=1; \
			fi; \
		done; \
	done; \
	if [ $$fail -eq 0 ]; then echo "shared/ copies in sync"; fi; \
	exit $$fail
