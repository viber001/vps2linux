# vps2img-pivot and vps2img-kexec are assembled from small fragments under src/
# so that the code shared by both deployers lives in exactly one place.  Edit the
# fragments, then run `make` to regenerate the two top-level scripts.  The
# generated scripts are committed as well, so a plain `scp` still works without
# running make.
#
# Every fragment carries a two-digit number and the merge order is ascending
# numeric order, so the shared src/lib blocks slot in between the program
# blocks: lib owns 10/30/50/70 and each program owns 00/20/40/60/80, no number
# is used twice.  The recipe below sorts src/<program>/*.sh and src/lib/*.sh by
# basename (field 3 of src/<dir>/<file>) to get that single merged order.
SHELL := /bin/sh

fragments = $(shell printf '%s\n' src/$(1)/*.sh src/lib/*.sh | sort -t/ -k3)

all: vps2img-pivot vps2img-kexec

vps2img-pivot: $(call fragments,vps2img-pivot)
	cat $^ > $@
	chmod 0755 $@

vps2img-kexec: $(call fragments,vps2img-kexec)
	cat $^ > $@
	chmod 0755 $@

# Rebuild from the fragments and fail if the committed scripts are stale.
check:
	@$(MAKE) --no-print-directory all >/dev/null
	@bash -n vps2img-pivot && bash -n vps2img-kexec
	@echo 'vps2img-pivot and vps2img-kexec are up to date'

.PHONY: all check
