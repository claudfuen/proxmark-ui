# ProxmarkUI 0.1.0

![ProxmarkUI Scan view with demo tag data](https://raw.githubusercontent.com/claudfuen/proxmark-ui/v0.1.0/docs/images/scan-light.png)

The screenshot uses demo data.

The first Apple silicon build packages the Iceman Proxmark3 client, its required
libraries and data files, and matching full firmware images for Proxmark3 Easy
readers with at least 256 KB of flash and Proxmark3 RDV4 readers. The app can
scan the 13.56 MHz and 125 kHz bands, inspect saved dumps, and guide confirmed
write flows for supported tags. A firmware mismatch opens a model-confirmed
full image update flow that leaves the bootloader alone.

Download `ProxmarkUI-v0.1.0-macos-arm64.zip` and extract it. The app is ad hoc
signed and has not been notarized. If macOS blocks the first launch, use
**System Settings > Privacy & Security > Open Anyway** after attempting to
open it. No separate Iceman installation is needed. Check `SHA256SUMS.txt`
and the accompanying source and license assets before sharing the binary.

This is a prerelease because a physical firmware flash has not yet been
validated. The connected Proxmark3 Easy reader was left unchanged, so its
existing client and firmware protocol mismatch remains. The Easy image is a
slim build for 256 KB readers and omits advanced protocols. Confirm your exact
hardware model and flash capacity before choosing a firmware image. See the
[hardware and firmware guide](https://github.com/claudfuen/proxmark-ui#hardware-and-firmware)
for details. Screenshots show demo data and do not establish successful
physical scans or writes.
