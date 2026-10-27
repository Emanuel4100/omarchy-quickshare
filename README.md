# Quick Share for Omarchy

Send files between this PC and Android / Samsung Galaxy devices with the share sheet built into the phone or tablet. Nothing extra needs to be installed on the Android side.

The protocol is handled by [quickshare-direct](https://github.com/papshmeare/quickshare-direct). It connects over Bluetooth and moves to Wi-Fi Direct when it can, so the phone and PC don't need to be on the same Wi-Fi. Guest networks that block devices from each other work too. This plugin adds a bar icon, a small `quickshare` CLI, and an Accept/Decline prompt that works with Omarchy's notifications.

## Install

1. Install quickshare-direct from its [releases](https://github.com/papshmeare/quickshare-direct/releases) (Arch: `quickshare-direct-x86_64.pkg.tar.zst`, `sudo pacman -U`).
2. Open its ports and set your Wi-Fi region, so the direct Wi-Fi link can use 5 GHz:
   ```bash
   sudo ufw allow quickshare-direct
   sudo iw reg set IL   # your country; persist it in /etc/conf.d/wireless-regdom
   ```
3. Route its prompts through this plugin and enable the receiver and the plugin:
   ```bash
   mkdir -p ~/.config/quickshare-direct
   echo "PATH=$HOME/.config/omarchy/plugins/emanuel.quickshare/bin:/usr/share/omarchy/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin" >> ~/.config/quickshare-direct/env
   systemctl --user enable --now quickshare-direct
   omarchy plugin enable emanuel.quickshare
   ```

## Usage

| Bar icon | Action |
|---|---|
| Left click | Pick a recent file and send it to a device in receive mode |
| Middle click | Open Downloads |
| Right click | Menu: receiving on/off, fast Wi-Fi on/off, send a file, send the latest screenshot, open Downloads |

The icon is an outline while receiving is off. It changes to a down arrow while a file comes in and an up arrow while one goes out. Notifications use the plugin's own icon, and a received photo shows as a thumbnail.

**Receiving:** on the phone, share a file, pick this PC, and choose **Accept** in the menu that pops up. Files land in `~/Downloads`.

**Sending:** put the phone in Quick Share receive mode (or *Everyone*) first.

```bash
quickshare send ~/file.pdf
quickshare receive on|off|toggle
quickshare menu          # the right-click menu
quickshare status        # {"installed":…,"receiving":…,"fast":…}
quickshare fast on|off   # Wi-Fi Direct for transfers, see below
```

## Faster transfers: `quickshare fast on`

Over Bluetooth, transfers crawl at a few KB/s. quickshare-direct tries to switch to a Wi-Fi Direct link, but NetworkManager shuts down any Wi-Fi Direct group it didn't start itself, about a millisecond after it comes up (`P2P: WPA supplicant notified a group start but we are not trying to connect!`). So every transfer stays on Bluetooth.

`quickshare fast on` asks for your password, then installs `system/quickshare-fastlink` to `/usr/local/lib/omarchy-quickshare/` along with a drop-in for `quickshare-ap@.service`. During a transfer, the helper:

1. takes the Wi-Fi card away from NetworkManager;
2. hosts the Wi-Fi Direct group itself, on 2.4 GHz by default, because Galaxy phones won't join a group on 5745 MHz;
3. hands the card back and reconnects to your network when the transfer ends.

**This PC's Wi-Fi and internet pause for the length of the transfer.** To prefer other channels, set `QS_GO_FREQS="2437 5180 …"` in `/etc/default/quickshare-direct`. `quickshare fast off` puts quickshare-direct's own behaviour back.

## Why `bin/notify-send`

quickshare-direct asks "accept this transfer?" with a notification that has Accept and Decline buttons. Omarchy's notification popups don't draw action buttons, so the question could never be answered. The `bin/notify-send` shim, placed first on the receiver's `PATH`, handles this in two ways:

- A notification with several actions becomes an Omarchy picker menu.
- A single-action notification (like "Show in folder") stays a normal toast that runs the action when clicked.

Everything else goes to the real `notify-send`.
