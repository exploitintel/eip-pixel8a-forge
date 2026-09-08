# Pixel 8a Forge port working rules

This repository owns the Android host and deployment material for the Pixel 8a
Forge port. Forge itself remains in `eip-cve-public-v4`.

## Boundaries

- Target only Pixel 8a (`akita`) build `CP2A.260805.005` until another build is
  deliberately qualified.
- Use the Pixel 11 architecture as the reference design. Do not copy or depend
  on the retired Pixel 8a projects.
- Keep device-specific firmware, generated boot images, credentials, Docker
  data, exported images, and raw device captures out of Git.
- Do not modify the Pixel 11 repository while implementing this port.
- A repository change does not authorize a flash, reboot, service restart,
  routing change, model call, PoC execution, or lab build. Obtain an explicit
  operator checkpoint for each live class.
- Prefer the smallest functional change. Do not add speculative hardening or a
  second control plane.

## Workflow

- Establish the live invariant before changing code.
- Keep exact device, build, source, config, and artifact hashes recorded.
- Every live mutation needs a rollback artifact and a post-change check.
- Commit as `Exploit Intel <dev@exploit-intel.com>` with no AI attribution.
