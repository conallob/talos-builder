# talos-builder — Claude Code Guide

This repository builds custom Talos Linux images for the Raspberry Pi CM5 (and RPi 5).
It patches two upstream Siderolabs repos and a community SBC overlay to produce a bootable
raw disk image and an OCI installer image.

## Repo layout

```
Makefile                          — top-level orchestration (versions, build targets)
patches/
  siderolabs/pkgs/0001-…patch     — kernel source + config patch (switches to raspberrypi/linux)
  siderolabs/talos/0001-…patch    — modules-arm64.txt patch (RPi5 module list)
checkouts/                        — git-cloned at build time, not committed
  pkgs/                           — siderolabs/pkgs @ PKG_VERSION
  talos/                          — siderolabs/talos @ TALOS_VERSION
  sbc-raspberrypi5/               — talos-rpi5/sbc-raspberrypi5 @ SBCOVERLAY_VERSION
.github/workflows/build.yaml      — CI: builds on tag push, publishes to ghcr.io/conallob
```

## Key version variables (top of Makefile)

| Variable           | Controls                         | Upstream to check                          |
|--------------------|----------------------------------|--------------------------------------------|
| `PKG_VERSION`      | siderolabs/pkgs tag              | https://github.com/siderolabs/pkgs/tags    |
| `TALOS_VERSION`    | siderolabs/talos tag             | https://github.com/siderolabs/talos/tags   |
| `SBCOVERLAY_VERSION` | talos-rpi5/sbc-raspberrypi5 ref| https://github.com/talos-rpi5/sbc-raspberrypi5 |
| `REGISTRY_USERNAME`| ghcr.io namespace                | currently `conallob`                       |
| `EXTENSIONS`       | system extension OCI image       | gvisor pinned by digest                    |

## Build pipeline (in order)

```
make checkouts patches   # clone + patch the three repos
make kernel              # build RPi linux kernel (slow — 30–60 min)
make overlay             # build U-Boot + dtoverlays SBC overlay
make installer           # build installer image + raw disk image
make release             # re-tag installer with the git tag (CI only)
```

All make targets accept `REGISTRY` and `REGISTRY_USERNAME` overrides:
```
make REGISTRY=ghcr.io REGISTRY_USERNAME=myuser kernel
```

## Upgrading to a new Talos release

### Find the right PKG_VERSION

`PKG_VERSION` (siderolabs/pkgs) must match what the Talos release was built against.
Look it up in the upstream Talos Makefile for the target tag:

```
# In your browser or with curl:
https://github.com/siderolabs/talos/blob/vX.Y.Z/Makefile
# Search the page for "PKGS" — look for a line like:
#   PKGS ?= v1.11.0
```

### Patch-level release (e.g. v1.12.5 → v1.12.6)

These are low-risk. The kernel config and module list rarely change between patch releases.

1. Update `Makefile`:
   ```
   PKG_VERSION   = <pkgs tag from Talos Makefile>
   TALOS_VERSION = v1.12.6
   ```

2. Re-apply patches to verify they still apply cleanly:
   ```
   make clean checkouts patches
   ```
   If both patches apply without error, proceed directly to step 4.
   If either fails, follow the minor/major release steps below.

3. **Commit, tag, and push**:
   ```
   git commit -am "Bump to vX.Y.Z"
   git tag vX.Y.Z
   git push origin main --tags
   ```
   CI triggers on `v*.*.*` tags and publishes images + a GitHub Release.

### Minor or major release (e.g. v1.12.x → v1.13.x)

The upstream kernel config and/or `hack/modules-arm64.txt` are more likely to have
changed. Follow the full process:

1. **Clean up** any previous checkout:
   ```
   make clean
   ```

2. **Update versions** in `Makefile`:
   - Set `PKG_VERSION` to the matching `siderolabs/pkgs` tag (see above)
   - Set `TALOS_VERSION` to the new `siderolabs/talos` tag

3. **Clone the new checkouts**:
   ```
   make checkouts
   ```

4. **Apply existing patches** and fix any failures:
   ```
   make patches
   ```
   If `patches-pkgs` fails → the pkgs kernel config or Pkgfile changed; update
   `patches/siderolabs/pkgs/0001-Patched-for-Raspberry-Pi-5.patch`.

   If `patches-talos` fails → `hack/modules-arm64.txt` changed upstream; regenerate
   the patch (see section below).

5. **After patches apply cleanly**, review the diff for the new Talos release:
   - New kernel modules added upstream may be BCM/RPi-relevant (keep them) or
     x86/server-only (drop them from `modules-arm64.txt`).
   - Check the pkgs config diff: any module changed from `=m` to `=y` must be
     removed from `modules-arm64.txt`; any new `=m` module that is RPi-relevant
     should be added.

6. **Commit, tag, and push** to trigger CI:
   ```
   git commit -am "Bump to vX.Y.Z"
   git tag vX.Y.Z
   git push origin main --tags
   ```
   CI triggers on `v*.*.*` tags and publishes images + a GitHub Release.

## Regenerating the talos patch (hack/modules-arm64.txt)

When `patches-talos` fails, the upstream `hack/modules-arm64.txt` has changed and the
patch context no longer matches. Steps:

1. Recover the intended RPi5 module list from the old patch + old base:
   ```
   # Apply old patch to the previous talos tag to see the desired output
   git show vOLD:hack/modules-arm64.txt > /tmp/old-base.txt
   cp /tmp/old-base.txt checkouts/talos/hack/modules-arm64.txt
   git -C checkouts/talos apply ../../patches/siderolabs/talos/0001-Patched-for-Raspberry-Pi-5.patch
   cp checkouts/talos/hack/modules-arm64.txt /tmp/rpi5-desired.txt
   ```

2. Restore the new upstream file and compare:
   ```
   git -C checkouts/talos checkout HEAD -- hack/modules-arm64.txt
   # Find new modules added upstream (may need to be added or dropped):
   comm -23 <(sort checkouts/talos/hack/modules-arm64.txt) <(sort /tmp/old-base.txt)
   ```
   - Keep new BCM/RPi-relevant modules (e.g. `irq-bcm2712-mip`, `vc4`, `v3d`).
   - Drop x86/server-only additions (Intel NIC internals, vdpa stack, etc.).

3. Write the new desired file into the checkout and commit:
   ```
   cp /tmp/rpi5-updated.txt checkouts/talos/hack/modules-arm64.txt
   git -C checkouts/talos add hack/modules-arm64.txt
   git -C checkouts/talos commit --no-gpg-sign -m "Patched for Raspberry Pi 5"
   git -C checkouts/talos format-patch HEAD~1 \
       --output-directory patches/siderolabs/talos/
   # Rename if needed to 0001-Patched-for-Raspberry-Pi-5.patch
   ```

4. Verify the new patch applies cleanly:
   ```
   git -C checkouts/talos checkout HEAD~1 -- hack/modules-arm64.txt
   git -C checkouts/talos apply ../../patches/siderolabs/talos/0001-Patched-for-Raspberry-Pi-5.patch
   ```

## CI / Release

- Workflow: `.github/workflows/build.yaml`
- Triggered by: `git push origin vX.Y.Z` (tag matching `v*.*.*`)
- Runner: `ubuntu-24.04-arm` (native ARM64)
- Artifacts published to: `ghcr.io/conallob/` (kernel, installer, imager, sbc overlay)
- GitHub Release created automatically with `metal-arm64.raw.zst`

## Installing on hardware

**Fresh install** (flash raw image):
```
unzstd metal-arm64.raw.zst
dd if=metal-arm64.raw of=/dev/sdX bs=4M status=progress && sync
```

**Upgrade existing node**:
```
talosctl upgrade --nodes <NODE_IP> --image ghcr.io/conallob/installer:vX.Y.Z
```

## Known limitations

- USB boot is not supported — USB is only available after Linux boots (not in U-Boot).
- Tested hardware: Raspberry Pi CM5, CM5 Lite (DeskPi Super6C), RPi 5B.
