PACKER_DIR        := packer
VAR_FILE          ?= build.pkrvars.hcl
VALIDATE_VAR_FILE ?= ci.pkrvars.hcl
# Var files in repo root; Packer runs from packer/ (flags must follow the subcommand).
VAR_FILE_FLAG     := -var-file=../$(VAR_FILE)

BASE_IMAGE        ?=

# Optional Quay publish (see example.quay.env, docs/quay-publish.md)
QUAY_ENV          ?= quay.env
PUSH_QUAY         ?= 0
GOLDEN_QCOW2      ?= $(firstword $(wildcard output/windows-server-*.qcow2))

# Run from packer/ on "." so variables.pkr.hcl + locals.pkr.hcl load; -only must be the full build id (packer 1.11+).
PACKER_ONLY_GOLDEN     := -only=windows-golden-image.qemu.windows
PACKER_ONLY_INSTALL    := -only=windows-install-only.qemu.install
PACKER_ONLY_PROVISION  := -only=windows-golden-provision-only.qemu.from_install

.PHONY: help init validate build build-install build-provision-only build-2022 build-2025 build-push download-virtio stage-virtio push-quay clean clean-force

help:
	@echo "Targets:"
	@echo "  init            Install Packer plugins"
	@echo "  validate        Validate Packer templates"
	@echo "  build                  One VM: install + provision + sysprep"
	@echo "  build-install          Pass 1 only: Windows install to *-install.qcow2"
	@echo "  build-provision-only   Pass 2 only: BASE_IMAGE=path/to-install.qcow2"
	@echo "  build-2022             Build Windows Server 2022 Standard"
	@echo "  build-2025             Build Windows Server 2025 Standard"
	@echo "  download-virtio Download virtio-win ISO and stage drivers for the config CD"
	@echo "  stage-virtio    Extract VirtIO drivers from downloads/virtio-win.iso"
	@echo "  push-quay       Push output/*.qcow2 to Quay (configure quay.env)"
	@echo "  build-push      make build then push-quay"
	@echo "  clean           Kill Packer QEMU VMs and remove build artifacts"
	@echo "  clean-force     clean, ignoring QEMU processes that refuse to exit"

init:
	cd $(PACKER_DIR) && packer init .

validate: init
	cd $(PACKER_DIR) && rm -rf ci-output && touch ci-stub.iso && packer validate -var-file=$(VALIDATE_VAR_FILE) -except=windows-golden-provision-only.qemu.from_install .

build: stage-virtio init
	@test -f drivers/viostor/2k22/amd64/viostor.sys || (echo "Run: make stage-virtio" >&2; exit 1)
	@if [ -d drivers/viostor/2k12 ]; then echo "drivers/ is bloated (old full virtio-win tree). Run: STAGE_FORCE=1 make stage-virtio" >&2; exit 1; fi
	rm -rf packer/output packer/output/packer-win* packer/packer_cache 2>/dev/null || true
	cd $(PACKER_DIR) && packer build -force $(VAR_FILE_FLAG) $(PACKER_ONLY_GOLDEN) .
	@if [ "$(PUSH_QUAY)" = "1" ]; then $(MAKE) push-quay; fi

build-install: stage-virtio init
	@test -f drivers/viostor/2k22/amd64/viostor.sys || (echo "Run: make stage-virtio" >&2; exit 1)
	rm -rf packer/output packer/output/packer-win* packer/packer_cache 2>/dev/null || true
	cd $(PACKER_DIR) && packer build -force $(VAR_FILE_FLAG) $(PACKER_ONLY_INSTALL) .

build-provision-only: stage-virtio init
	@test -n "$(BASE_IMAGE)" || (echo "Set BASE_IMAGE=output/...-install.qcow2 from make build-install" >&2; exit 1)
	@test -f "$(abspath $(BASE_IMAGE))" || (echo "BASE_IMAGE not found: $(BASE_IMAGE)" >&2; exit 1)
	cd $(PACKER_DIR) && packer build -force $(VAR_FILE_FLAG) -var base_image_path=$(abspath $(BASE_IMAGE)) $(PACKER_ONLY_PROVISION) .

build-2022: stage-virtio init
	cd $(PACKER_DIR) && packer build -force $(VAR_FILE_FLAG) -var windows_version=2022 -var windows_edition=Standard $(PACKER_ONLY_GOLDEN) .

build-2025: stage-virtio init
	cd $(PACKER_DIR) && packer build -force $(VAR_FILE_FLAG) -var windows_version=2025 -var windows_edition=Standard $(PACKER_ONLY_GOLDEN) .

download-virtio:
	./scripts/download-prerequisites.sh virtio

stage-virtio:
	@test -f downloads/virtio-win.iso || (echo "Run: make download-virtio" >&2; exit 1)
	./scripts/stage-virtio-drivers.sh downloads/virtio-win.iso

push-quay:
	@test -n "$(GOLDEN_QCOW2)" || (echo "No golden qcow2 under output/ (run make build first)" >&2; exit 1)
	@test -f "$(GOLDEN_QCOW2)" || (echo "qcow2 not found: $(GOLDEN_QCOW2)" >&2; exit 1)
	@test -f "$(QUAY_ENV)" || (echo "Copy example.quay.env to $(QUAY_ENV) and set QUAY_IMAGE_* refs" >&2; exit 1)
	QUAY_ENV_FILE="$(abspath $(QUAY_ENV))" ./scripts/push-qcow2-to-quay.sh "$(abspath $(GOLDEN_QCOW2))"

build-push: build push-quay

clean:
	./scripts/clean-build.sh

clean-force:
	FORCE=1 ./scripts/clean-build.sh
