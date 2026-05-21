PACKER_DIR        := packer
VAR_FILE          ?= example.pkrvars.hcl
VALIDATE_VAR_FILE ?= ci.pkrvars.hcl
PACKER            := packer -var-file=$(VAR_FILE)

.PHONY: help init validate build build-2022 build-2025 download-virtio clean

help:
	@echo "Targets:"
	@echo "  init            Install Packer plugins"
	@echo "  validate        Validate Packer templates"
	@echo "  build           Build image (windows_version from $(VAR_FILE))"
	@echo "  build-2022      Build Windows Server 2022 Standard"
	@echo "  build-2025      Build Windows Server 2025 Standard"
	@echo "  download-virtio Download latest virtio-win ISO"
	@echo "  clean           Remove output artifacts"

init:
	cd $(PACKER_DIR) && packer init .

validate: init
	cd $(PACKER_DIR) && rm -rf ci-output && touch ci-stub.iso && packer validate -var-file=$(VALIDATE_VAR_FILE) .

build: init
	cd $(PACKER_DIR) && $(PACKER) build -force .

build-2022: validate
	cd $(PACKER_DIR) && $(PACKER) build -force -var windows_version=2022 -var windows_edition=Standard .

build-2025: validate
	cd $(PACKER_DIR) && $(PACKER) build -force -var windows_version=2025 -var windows_edition=Standard .

download-virtio:
	./scripts/download-prerequisites.sh virtio

clean:
	rm -rf output packer/packer_cache packer_cache
