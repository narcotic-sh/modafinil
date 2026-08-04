# Modafinil

A macOS menu bar app that prevents your MacBook from falling asleep, both when the lid is open and when the lid is closed.

When the lid is closed, it lets the display turn off like normal to preserve battery and reduce heat.

Motivated by the need to let coding agents stay running while you carry your MacBook around.

<p>
  <img width="516" height="254" alt="demo" src="https://github.com/user-attachments/assets/b6e27ae7-46af-4497-ab59-fe7f5642cc41" />
</p>

## Installation & Usage

Install through the latest `.dmg` in Releases. Supports both Apple Silicon and Intel Macs (universal binary).

Requires App Background Activity permission (`System Settings -> General -> Login Items & Extensions`). Should pop up automatically on first activation.

Left click to activate/deactivate. Right click for menu, where you can optionally set a time limit or a battery safety threshold, quit the app, and also uninstall it.

The battery safety threshold restores normal sleep behavior when the Mac is running on battery and reaches the selected charge level. If the lid is closed, the Mac goes to sleep immediately. The setting is off by default.

Requires macOS 13+.
