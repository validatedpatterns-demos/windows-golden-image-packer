PACKER_DIR        := packer
VAR_FILE          ?= build.pkrvars.hcl
VALIDATE_VAR_FILE ?= ci.pkrvars.hcl
# Var files in repo root; Packer runs from packer/ (flags must follow the subcommand).
VAR_FILE_FLAG     := -var-file=../$(VAR_FILE)

BASE_IMAGE        ?=

# Versions built by default (sequential). Override: make build BUILD_VERSIONS="2022"
BUILD_VERSIONS    ?= 2022 2025
WINDOWS_EDITION   ?= Standard

# Optional Quay publish (see example.quay.env, docs/quay-publish.md)
QUAY_ENV          ?= quay.env
PUSH_QUAY         ?= 0
GOLDEN_QCOW2      ?=

# Run from packer/ on "." so variables.pkr.hcl + locals.pkr.hcl load; -only must be the full build id (packer 1.11+).
PACKER_ONLY_GOLDEN     := -only=windows-golden-image.qemu.windows
PACKER_ONLY_INSTALL    := -only=windows-install-only.qemu.install
PACKER_ONLY_PROVISION  := -only=windows-golden-provision-only.qemu.from_install

# Packer deletes output_directory at the start of each build (-force) and on failure/cancel
# (default -on-error=cleanup). Per-version staging keeps install media separate from packer work/.
PACKER_STAGING         = .packer-$(VERSION)
PACKER_WORK_SUBDIR     = work
# abort: keep VM/qcow2 on Ctrl+C or provision failure (retry with build-provision-only). cleanup: Packer default.
PACKER_ON_ERROR       ?= abort

.PHONY: help init validate build build-versions build-version build-install build-provision-only build-2022 build-2025 build-push download-virtio stage-virtio push-quay optimize-image image-size boot-test boot-test-all boot-test-2022 boot-test-2025 boot-test-image inspect-image extract-sysprep-log clean clean-force

help:
	@echo "Targets:"
	@echo "  init            Install Packer plugins"
	@echo "  validate        Validate Packer templates"
	@echo "  build                  Build $(BUILD_VERSIONS) sequentially (install + provision + sysprep)"
	@echo "  build-version          Build one version: make build-version VERSION=2025"
	@echo "  build-install          Pass 1 only: make build-install VERSION=2025"
	@echo "  build-provision-only   Pass 2 only: BASE_IMAGE=path/to-install.qcow2"
	@echo "  build-2022             Build Windows Server 2022 only"
	@echo "  build-2025             Build Windows Server 2025 only"
	@echo "  download-virtio Download virtio-win ISO and stage drivers for the config CD"
	@echo "  stage-virtio    Extract VirtIO drivers from downloads/virtio-win.iso"
	@echo "  push-quay       Push all golden qcow2 images found to Quay (quay.env)"
	@echo "  optimize-image  Re-encode golden qcow2(s) for smaller file size (IMAGE_OPTIMIZE=0 skips auto step in build)"
	@echo "  image-size      Report virtual size (DataVolume min) and file size for golden qcow2(s)"
	@echo "  boot-test       Boot-test newest golden image (virtio disk, copy-on-write overlay)"
	@echo "  boot-test-all   Boot-test every golden qcow2 under output/"
	@echo "  boot-test-2022  boot-test-2025   version-specific boot tests"
	@echo "  boot-test-image IMAGE=path/to.qcow2   test one file"
	@echo "  inspect-image IMAGE=path/to.qcow2     partition/firmware hints"
	@echo "  extract-sysprep-log [IMAGE=...] [OUT_DIR=./golden-logs]  sysprep diagnostics from qcow2"
	@echo "  build-push      make build then push-quay (all images found)"
	@echo "  clean           Kill Packer QEMU + libvirt build/boot-test VMs; remove artifacts"
	@echo "  clean-force     clean, ignoring QEMU processes that refuse to exit"
	@echo ""
	@echo "  PACKER_ON_ERROR=abort (default) keeps qcow2 on Ctrl+C; use make clean to wipe output/"

init:
	cd $(PACKER_DIR) && packer init .

validate: init
	./scripts/prepare-ci-validate.sh
	cd $(PACKER_DIR) && packer validate -var-file=$(VALIDATE_VAR_FILE) .

build: stage-virtio init
	@test -f drivers/viostor/2k22/amd64/viostor.sys || (echo "Run: make stage-virtio" >&2; exit 1)
	@if [ -d drivers/viostor/2k12 ]; then echo "drivers/ is bloated (old full virtio-win tree). Run: STAGE_FORCE=1 make stage-virtio" >&2; exit 1; fi
	@set -e; for v in $(BUILD_VERSIONS); do \
	  rm -rf "output/.packer-$$v" "packer/output/.packer-$$v"; \
	  rm -f "output/windows-server-$$v-"*.qcow2 "packer/output/windows-server-$$v-"*.qcow2; \
	done
	rm -rf packer/packer_cache 2>/dev/null || true
	$(MAKE) build-versions
	@if [ "$(PUSH_QUAY)" = "1" ]; then $(MAKE) push-quay; fi

build-versions:
	@set -e; \
	for v in $(BUILD_VERSIONS); do \
	  echo "=== Building Windows Server $$v ==="; \
	  $(MAKE) build-version VERSION=$$v; \
	done

# One Windows Server version; does not wipe other versions already in output/
build-version:
	@test -n "$(VERSION)" || (echo "Set VERSION=2022 or VERSION=2025" >&2; exit 1)
	@test -f drivers/viostor/2k22/amd64/viostor.sys || (echo "Run: make stage-virtio" >&2; exit 1)
	@efi="$$(./scripts/read-pkrvar.sh efi_boot $(VAR_FILE) true)"; \
	if [ "$$efi" = "true" ]; then \
	  $(MAKE) build-version-uefi VERSION=$(VERSION); \
	else \
	  $(MAKE) build-version-bios VERSION=$(VERSION); \
	fi

# SeaBIOS single-pass Packer build (efi_boot=false only)
build-version-bios:
	@test -n "$(VERSION)" || (echo "Set VERSION=2022 or VERSION=2025" >&2; exit 1)
	mkdir -p "output/$(PACKER_STAGING)/$(PACKER_WORK_SUBDIR)"
	rm -f output/windows-server-$(VERSION)-*.qcow2 packer/output/windows-server-$(VERSION)-*.qcow2 \
		packer/output/packer-win$(VERSION)-* 2>/dev/null || true
	cd $(PACKER_DIR) && packer build -force -on-error=$(PACKER_ON_ERROR) $(VAR_FILE_FLAG) \
		-var windows_version=$(VERSION) -var windows_edition=$(WINDOWS_EDITION) \
		-var efi_boot=false \
		-var output_directory=../output/$(PACKER_STAGING)/$(PACKER_WORK_SUBDIR) \
		$(PACKER_ONLY_GOLDEN) .
	./scripts/promote-golden-output.sh "$(VERSION)" "$(PACKER_STAGING)"

# UEFI: virt-install install, then Packer provision + sysprep (OpenShift-ready)
build-version-uefi:
	@test -n "$(VERSION)" || (echo "Set VERSION=2022 or VERSION=2025" >&2; exit 1)
	@command -v virt-install >/dev/null || (echo "virt-install required for efi_boot=true (dnf install virt-install)" >&2; exit 1)
	mkdir -p "output/$(PACKER_STAGING)/$(PACKER_WORK_SUBDIR)"
	rm -f output/windows-server-$(VERSION)-*.qcow2 packer/output/windows-server-$(VERSION)-*.qcow2 2>/dev/null || true
	@edition_lc="$$(echo '$(WINDOWS_EDITION)' | tr '[:upper:]' '[:lower:]')"; \
	install="output/$(PACKER_STAGING)/packer-win$(VERSION)-$$edition_lc-install.qcow2"; \
	if [ "$(SKIP_INSTALL)" = "1" ] && [ -f "$$install" ]; then \
	  echo "SKIP_INSTALL=1: reusing $$install"; \
	else \
	  VERSION=$(VERSION) WINDOWS_EDITION=$(WINDOWS_EDITION) PACKER_STAGING=$(PACKER_STAGING) \
		./scripts/build-uefi-virt-install.sh; \
	fi; \
	test -f "$$install" || install="output/$(PACKER_STAGING)/packer-win$(VERSION)-$$edition_lc-install"; \
	test -f "$$install" || (echo "UEFI install disk not found under output/$(PACKER_STAGING)" >&2; exit 1); \
	cd $(PACKER_DIR) && packer build -force -on-error=$(PACKER_ON_ERROR) $(VAR_FILE_FLAG) \
		-var windows_version=$(VERSION) -var windows_edition=$(WINDOWS_EDITION) \
		-var efi_boot=true \
		-var install_disk_interface=sata \
		-var base_image_path=../$$install \
		-var output_directory=../output/$(PACKER_STAGING)/$(PACKER_WORK_SUBDIR) \
		$(PACKER_ONLY_PROVISION) .
	./scripts/promote-golden-output.sh "$(VERSION)" "$(PACKER_STAGING)"

build-install: stage-virtio init
	@test -n "$(VERSION)" || (echo "Set VERSION=2022 or VERSION=2025 (install uses product_key_2022 or product_key_2025 for that version)" >&2; exit 1)
	@test -f drivers/viostor/2k22/amd64/viostor.sys || (echo "Run: make stage-virtio" >&2; exit 1)
	rm -rf packer/output packer/output/packer-win* packer/packer_cache 2>/dev/null || true
	cd $(PACKER_DIR) && packer build -force -on-error=$(PACKER_ON_ERROR) $(VAR_FILE_FLAG) \
		-var windows_version=$(VERSION) -var windows_edition=$(WINDOWS_EDITION) \
		$(PACKER_ONLY_INSTALL) .

build-provision-only: stage-virtio init
	@test -n "$(BASE_IMAGE)" || (echo "Set BASE_IMAGE=output/...-install.qcow2 from make build-install" >&2; exit 1)
	@test -f "$(abspath $(BASE_IMAGE))" || (echo "BASE_IMAGE not found: $(BASE_IMAGE)" >&2; exit 1)
	@staging_dir="$$(dirname "$(abspath $(BASE_IMAGE))")"; \
	work_dir="$$staging_dir/work"; \
	mkdir -p "$$work_dir"; \
	efi="$$(./scripts/read-pkrvar.sh efi_boot $(VAR_FILE) true)"; \
	cd $(PACKER_DIR) && packer build -force -on-error=$(PACKER_ON_ERROR) $(VAR_FILE_FLAG) \
		-var base_image_path=$(abspath $(BASE_IMAGE)) \
		-var efi_boot=$$efi \
		-var output_directory=$$work_dir \
		$(PACKER_ONLY_PROVISION) .

build-2022: stage-virtio init
	$(MAKE) build-version VERSION=2022

build-2025: stage-virtio init
	$(MAKE) build-version VERSION=2025

download-virtio:
	./scripts/download-prerequisites.sh virtio

stage-virtio:
	@test -f downloads/virtio-win.iso || (echo "Run: make download-virtio" >&2; exit 1)
	./scripts/stage-virtio-drivers.sh downloads/virtio-win.iso

push-quay:
	@test -f "$(QUAY_ENV)" || (echo "Copy example.quay.env to $(QUAY_ENV) and set QUAY_IMAGE_* refs" >&2; exit 1)
	@if [ -n "$(GOLDEN_QCOW2)" ]; then \
	  echo "Using golden image: $(GOLDEN_QCOW2)"; \
	  QUAY_ENV_FILE="$(abspath $(QUAY_ENV))" ./scripts/push-qcow2-to-quay.sh "$(abspath $(GOLDEN_QCOW2))"; \
	else \
	  found=0; \
	  while IFS= read -r qcow2; do \
	    [ -z "$$qcow2" ] && continue; \
	    found=1; \
	    echo "=== Pushing $$qcow2 ==="; \
	    QUAY_ENV_FILE="$(abspath $(QUAY_ENV))" ./scripts/push-qcow2-to-quay.sh "$$(cd "$$(dirname "$$qcow2")" && pwd)/$$(basename "$$qcow2")"; \
	  done < <(./scripts/find-golden-qcow2.sh --all); \
	  test "$$found" -eq 1 || (echo "No golden qcow2 under output/ or packer/output/" >&2; exit 1); \
	fi

build-push: build push-quay

optimize-image:
	@if [ -n "$(GOLDEN_QCOW2)" ]; then \
	  ./scripts/optimize-qcow2.sh "$(abspath $(GOLDEN_QCOW2))"; \
	else \
	  ./scripts/optimize-qcow2.sh --all; \
	fi

image-size:
	@if [ -n "$(GOLDEN_QCOW2)" ]; then \
	  ./scripts/qcow2-size-report.sh "$(abspath $(GOLDEN_QCOW2))"; \
	else \
	  ./scripts/qcow2-size-report.sh --all; \
	fi

boot-test:
	./scripts/boot-test-golden.sh

boot-test-all:
	./scripts/boot-test-golden.sh --all

boot-test-2022:
	./scripts/boot-test-golden.sh --version 2022

boot-test-2025:
	./scripts/boot-test-golden.sh --version 2025

boot-test-image:
	@test -n "$(IMAGE)" || (echo "Set IMAGE=path/to/windows-server-*.qcow2" >&2; exit 1)
	./scripts/boot-test-image.sh --image "$(abspath $(IMAGE))"

inspect-image:
	@test -n "$(IMAGE)" || (echo "Set IMAGE=path/to/windows-server-*.qcow2" >&2; exit 1)
	./scripts/inspect-golden-qcow2.sh "$(abspath $(IMAGE))"

extract-sysprep-log:
	@if [ -n "$(GOLDEN_QCOW2)" ]; then \
	  img="$(abspath $(GOLDEN_QCOW2))"; \
	elif [ -n "$(IMAGE)" ]; then \
	  img="$(abspath $(IMAGE))"; \
	else \
	  img="$$(./scripts/find-golden-qcow2.sh)"; \
	fi; \
	echo "Using image: $$img" >&2; \
	out="$${OUT_DIR:-./golden-logs}/sysprep-diagnostics.log"; \
	rm -f "$$out"; \
	./scripts/extract-sysprep-setuperr.sh "$$img" "$$out"; \
	cat "$$out"

clean:
	./scripts/clean-build.sh

clean-force:
	FORCE=1 ./scripts/clean-build.sh
