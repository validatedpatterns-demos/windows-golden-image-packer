<!--
  Copyright 2026 Red Hat, Inc.
  SPDX-License-Identifier: Apache-2.0
  virt-install pass 1 only: power off so virt-install wait returns.
-->

        <SynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Description>Shut down after unattended install (virt-install pass 1)</Description>
          <CommandLine>shutdown.exe /s /t 30 /f /c "Golden image install complete"</CommandLine>
        </SynchronousCommand>
