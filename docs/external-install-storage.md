# External install storage

The experimental USB option puts the 64 GiB guest disk, IPSW download and large
restore extraction cache on the folder selected through Files. A security-scoped
bookmark is retained while either the downloader or the native restore uses it.

The USB parent contains:

- `Henge-<machine UUID>/disk.img`: fully allocated disk with its owner marker.
- `Henge Installer/Downloads/<build>.ipsw`: completed download and completion receipt.
- `Henge Installer/Downloads/<build>.ipsw.part`: interrupted download with HTTP validator metadata.
- `Henge Installer/Restore-<machine UUID>/`: restore extraction cache. Removed after a successful restore.

An existing `Henge Installer` directory without the expected owner marker is
refused. Guest disks and interrupted restore folders are preserved after failure;
they are not inferred to be disposable merely because the USB drive is unplugged.

External downloads use URLSession **data** callbacks and write directly to a file
on USB. A URLSession download task would stage the entire 16+ GB IPSW internally
before its completion callback. Interrupted streaming transfers use Range and
If-Range with a strong ETag or Last-Modified validator. Wrong ranges and changed
validators are rejected, and an HTTP 200 response restarts the owned partial
instead of appending. Only the exact announced number of bytes gets a completion
receipt. A final image without a receipt is kept and refused rather than replaced.
TLS and the restore stack's image validation remain enabled; the receipt is not a
cryptographic verification of an IPSW.

ROM, identity, auxiliary storage, small framework temporary files and the guest
RAM fallback remain internal. A 2 GiB guest reserves approximately **4 GiB free
internally** before installation (2 GiB guest RAM scratch plus 2 GiB headroom).
USB preflight estimates a fully allocated 64 GiB disk, the download if not cached,
twice the catalog IPSW size for extraction, and 2 GiB reserve. These are estimates;
future restore images can require more space. Existing completed internal IPSWs
are reused in place.

Run `sh tests/external-storage/run.sh` on macOS for filesystem/HTTP validation and
actual loopback download/resume tests. The GitHub workflow also parses app sources
with the iOS SDK; the IPA build separately type-checks and links the whole app.
These checks do not demonstrate a successful macOS boot on a 4 GB iPad, real USB
scope behavior, cable stability or exFAT performance. Those require device testing.
