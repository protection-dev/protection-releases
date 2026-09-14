# Protection — public OTA release channel

This repository hosts the public over-the-air update channel for the Protection
app (Android APK + Windows desktop). Devices fetch release assets and the
`update.json` / `desktop-update.json` manifests directly from here with no
credential. Contents are published automatically by CI on the source repo.
