<p align="center">
  <img src="docs/assets/controlpower-logo.png" alt="ControlPower" width="900">
</p>

# ControlPower

ControlPower keeps your Mac awake from the menu bar, even when a MacBook lid is closed. It controls macOS sleep behavior without making you live in Terminal.

I tried using amphetamine, but everytime i would close my macbooks lid, the mac would eventually go to sleep. so i created controlpower.

[Download the latest notarized DMG](https://github.com/mohkg1017/ControlPower/releases/latest)

<p align="center">
  <img src="docs/assets/controlpower-menu-panel.png" alt="ControlPower menu bar panel showing No Sleep Active and Sleep Display controls" width="600">
</p>

Perfect for MacBooks: close the lid, keep the Mac running, and let the built-in display turn fully off instead of sitting dimmed.

## Features

- Keep your Mac awake after closing the lid.
- Turn the display fully off while the Mac stays running.
- Toggle `disablesleep` with one click from the menu bar.
- Restore safe defaults for `disablesleep` and `lidwake`.
- Uses a signed helper for system-level changes.

## Requirements

- macOS 26.0 or later
- Apple silicon or Intel Mac

## Install

1. Download `ControlPower-1.0.0.dmg` from the latest release.
2. Open the DMG and drag ControlPower into Applications.
3. Launch ControlPower and approve the helper when macOS asks.

## Privacy

ControlPower does not collect analytics or user data. The release pipeline checks the app and DMG before upload so local files, credentials, and private machine paths are not accidentally shipped.
