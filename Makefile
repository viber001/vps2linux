# vps2img-pivot and vps2img-kexec are assembled from small fragments under src/
# so that the code shared by both deployers lives in exactly one place.  Edit the
# fragments, then run `make` to regenerate the two top-level scripts.  The
# generated scripts are gitignored (only the fragments are tracked), so run
# `make` before copying or scp'ing a script to a target.
#
# Every fragment carries a leading number and is merged in ascending numeric
# order, so the shared src/lib blocks slot in between the program blocks: lib
# owns 10/30/50/70 and each program owns 00/20/40/60/80, no number is used
# twice.  tools/build.py also resolves the small directive language (see
# docs/preprocessor.md) that lets a fragment pull a shared body -- such as the
# Combustion script -- out of src/assets/ and substitute @KEY@ placeholders.
SHELL := /bin/sh

sources = $(wildcard src/vps2img-pivot/*.sh src/vps2img-kexec/*.sh src/lib/*.sh src/assets/*.sh tools/build.py)

all: vps2img-pivot vps2img-kexec

vps2img-pivot: $(sources)
	python3 tools/build.py --program vps2img-pivot \
		--dirs src/vps2img-pivot src/lib --assets src/assets > $@
	chmod 0755 $@

vps2img-kexec: $(sources)
	python3 tools/build.py --program vps2img-kexec \
		--dirs src/vps2img-kexec src/lib --assets src/assets > $@
	chmod 0755 $@

# Rebuild from the fragments and syntax-check the generated scripts.
check:
	@$(MAKE) --no-print-directory all >/dev/null
	@bash -n vps2img-pivot && bash -n vps2img-kexec
	@echo 'vps2img-pivot and vps2img-kexec rebuilt and syntax-checked'

.PHONY: all check
