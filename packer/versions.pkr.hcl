# Copyright 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0

packer {
  required_version = ">= 1.9.0"

  required_plugins {
    qemu = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/qemu"
    }
  }
}
