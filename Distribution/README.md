# SiemensIPGiver Distribution

This folder contains the release packaging flow for distributing SiemensIPGiver outside the Mac App Store without asking users to disable Gatekeeper, SIP, or other macOS security features.

## What the Package Installs

- `/Applications/SiemensIPGiver.app`
- `/Library/Application Support/SiemensIPGiver/SiemensIPGiverBPFSetup.sh`
- `/Library/LaunchDaemons/com.gmaendel.SiemensIPGiver.bpf.plist`

The LaunchDaemon grants `/dev/bpf*` read/write access to the local `siemensipgiver-bpf` group at install time and boot time. The installer adds the current console user to that group.

## Build

```sh
Distribution/build-release.sh
```

The script archives the app, exports a Developer ID signed `.app`, creates a `.pkg`, signs the `.pkg` when a Developer ID Installer certificate is available, and notarizes when `NOTARY_PROFILE` is set.

## Required Local Credentials

The app signing certificate must be available in the login keychain:

```text
Developer ID Application: Rite Irrigation LLC (5UAM478N24)
```

The installer signing certificate must also be available:

```text
Developer ID Installer: Rite Irrigation LLC (5UAM478N24)
```

Create the notary keychain profile once:

```sh
xcrun notarytool store-credentials SiemensIPGiverNotary \
  --apple-id "YOUR_APPLE_ID" \
  --team-id 5UAM478N24
```

Then build, sign, notarize, and staple:

```sh
NOTARY_PROFILE=SiemensIPGiverNotary Distribution/build-release.sh
```
