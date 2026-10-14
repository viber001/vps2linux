# vps2img-pivot and vps2img-kexec are assembled from small fragments under src/ so
# that the code shared by both deployers lives in exactly one place.  Edit the
# fragments, then run `make` to regenerate the two top-level scripts.  The
# generated scripts are committed as well, so a plain `scp` still works without
# running make.
SHELL := /bin/sh

VPS2IMG_PIVOT_SRC := \
	src/vps2img-pivot/00-head.sh \
	src/lib/10-basic.sh \
	src/vps2img-pivot/10-gap1.sh \
	src/lib/20-paths.sh \
	src/vps2img-pivot/20-gap2.sh \
	src/lib/30-source.sh \
	src/vps2img-pivot/30-gap3.sh \
	src/lib/40-gpt.sh \
	src/vps2img-pivot/40-tail.sh

VPS2IMG_KEXEC_SRC := \
	src/vps2img-kexec/00-head.sh \
	src/lib/10-basic.sh \
	src/vps2img-kexec/10-gap1.sh \
	src/lib/20-paths.sh \
	src/vps2img-kexec/20-gap2.sh \
	src/lib/30-source.sh \
	src/vps2img-kexec/30-gap3.sh \
	src/lib/40-gpt.sh \
	src/vps2img-kexec/40-tail.sh

all: vps2img-pivot vps2img-kexec

vps2img-pivot: $(VPS2IMG_PIVOT_SRC)
	cat $(VPS2IMG_PIVOT_SRC) > $@
	chmod 0755 $@

vps2img-kexec: $(VPS2IMG_KEXEC_SRC)
	cat $(VPS2IMG_KEXEC_SRC) > $@
	chmod 0755 $@

# Rebuild from the fragments and fail if the committed scripts are stale.
check:
	@$(MAKE) --no-print-directory all >/dev/null
	@bash -n vps2img-pivot && bash -n vps2img-kexec
	@echo 'vps2img-pivot and vps2img-kexec are up to date'

.PHONY: all check
