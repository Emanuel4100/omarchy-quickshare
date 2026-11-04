# Notes: sending to Samsung phones, and fast transfers without dropping the Wi-Fi

These notes come from trying to fix two things in this plugin:

1. Sending from the PC to an Android phone (a Galaxy S24 Ultra) never found the phone.
2. Fast mode pauses the PC's Wi-Fi for as long as a transfer runs.

Last updated 2026-11-04. Test setup:

- **PC:** an Omarchy desktop with an Intel AX210 Wi-Fi card (`iwlwifi`), kernel 7.2, NetworkManager 1.58.1, wpa_supplicant 2.12, quickshare-direct 0.1.5.
- **Phones:** a Galaxy S24 Ultra and a Galaxy Tab S9+.

## Where things stand

| | Status |
|---|---|
| Phone → PC over Bluetooth, then Wi-Fi Direct (fast mode) | Works. The PC's Wi-Fi pauses during the transfer; about 5 MB/s. |
| PC → Galaxy phone: finding the phone | Fixed in v1.2.0 with a wake-up beacon (section 1). |
| PC → Galaxy phone: the transfer itself | Not confirmed yet. |
| Fast transfers that keep the PC's Wi-Fi connected | Works only with a patched NetworkManager (section 4): about 1.7 MB/s, and one of two big transfers stalled. |

## 1. Sending to Samsung phones: the wake-up beacon

- **How quickshare-direct finds a phone:** `quickshare-direct send` scans Bluetooth LE for the phone's receiver advertisement, service data under 0xFEF3 (`core_lib/src/hdl/gatt_client.rs`, `discover_receivers`). Upstream tested this with a Pixel only.
- **What Android phones wait for:** a phone on its Quick Share receive screen only announces itself after it hears a "device nearby is sharing" beacon: 0xFE2C service data that starts with Quick Share's model id `fc 12 8e`. Samsung phones don't announce themselves at all without it.
  - rQuickShare, mtch3n/quickshare and NearShare all send this beacon.
  - quickshare-direct's library has it (`hdl/blea.rs`, `BleAdvertiser`), but `send` never runs it.
- **The fix in v1.2.0:** [`scripts/qs-beacon`](../scripts/qs-beacon) sends the same 24 bytes through BlueZ (`LEAdvertisingManager1`, no root needed) while `quickshare send` and `quickshare devices` look for a phone. With it, `quickshare devices` found "Emanuel's S24 Ultra"; without it, the phone never showed up.
- **The phone is also on the local network:** phones announce Quick Share on the Wi-Fi network too (mDNS `_FC9F5ED42C8A._tcp`), even when visible only to their own contacts. `quickshare devices` lists them. quickshare-direct only sends over Bluetooth, so sending over the local network (mDNS + TCP, like rQuickShare) would be an upstream feature.
- **To report upstream:** quickshare-direct should run `BleAdvertiser` while `send` and `devices` scan.

## 2. Why fast mode pauses the Wi-Fi

### NetworkManager removes Wi-Fi Direct groups it didn't start

When anything other than NetworkManager starts a Wi-Fi Direct group through NetworkManager's wpa_supplicant, the group is gone about a millisecond later:

```
NetworkManager: device (p2p-dev-wlp6s0): P2P: WPA supplicant notified a group start but we are not trying to connect! Ignoring the event.
wpa_supplicant: p2p-wlp6s0-0: interface state ENABLED->DISABLED
wpa_supplicant: p2p-wlp6s0-0: AP-DISABLED
```

The mechanism, in NetworkManager 1.58:

1. `nm-supplicant-interface.c`, handler for the "GroupStarted" D-Bus signal: NetworkManager wraps the new group interface in an `NMSupplicantInterface` (`gs_unref_object`) and emits `GROUP_STARTED`.
2. `nm-device-wifi-p2p.c`, `supplicant_iface_group_started_cb`: the Wi-Fi P2P device isn't setting up a connection, so it logs "Ignoring the event" and returns.
3. The wrapper's last reference drops. `dispose()` calls `set_state_down(self, TRUE, …)`, and the `TRUE` means "remove in wpa_supplicant". wpa_supplicant's `RemoveInterface` tears the group down. That's why no `P2P-GROUP-REMOVED` shows up in the log.

No setting turns this off.

The only way around it with stock NetworkManager is to take the Wi-Fi card away from NetworkManager for the transfer. That's what fast mode's helper ([`system/quickshare-fastlink`](../system/quickshare-fastlink)) does, and it's why the Wi-Fi pauses.

At one point this looked like a channel or regulatory problem instead. The source and the logs above settled it.

### The card and the kernel

The card's own limits (from `iw phy`):

- **Interface combinations (AX210):** at most one normal Wi-Fi interface, one Wi-Fi Direct group and one Wi-Fi Direct management interface (`P2P-device`). A group may run on a second channel next to the connection (`#channels <= 2`). A plain hotspot (AP) has to share the connection's channel (`#channels <= 1`).
- **5 GHz is mostly "no IR"** (no initiating radiation) on Intel cards. A group could share a 5 GHz channel with the connection under the `IR-CONCURRENT` rule, but the kernel only honours that with `CONFIG_CFG80211_REG_RELAX_NO_IR`. That option depends on `CFG80211_CERTIFICATION_ONUS`, and distribution kernels (Arch included) leave it off.
  - So next to a 5 GHz connection, the group has to go on 2.4 GHz, as a second channel.
- **Galaxy phones won't join a group on 5745 MHz (UNII-3) or on radar (DFS) channels.**
  - On 2026-10-27 the router was on DFS channel 60. quickshare-direct's own helper put the group on 5745 MHz after leaving the network, and the group died at once.

### How other tools handle this

| Tool | How it moves data | The PC's Wi-Fi |
|---|---|---|
| LocalSend, KDE Connect, Warpinator, rQuickShare, NearDrop | Over the local network only | Untouched; both devices must be on the same network |
| OpenDrop + OWL (AirDrop on Linux) | AWDL, with the card in monitor mode | The card is taken over; in practice a second adapter |
| MiracleCast | Its own wpa_supplicant for Wi-Fi Direct | Clashes with NetworkManager; its FAQ says to stop NetworkManager |
| GNOME Network Displays | NetworkManager's own Wi-Fi Direct support | Kept, because NetworkManager started the group |
| Quick Share on Windows | Windows' Wi-Fi Direct; the phone hosts `DIRECT-xx` and the PC joins | Kept: the OS runs both |
| Quick Share on ChromeOS | shill (the connection manager) hosts or joins groups itself (`P2PManager`) | Kept: the connection manager runs both |

The ones that keep the Wi-Fi either never leave the local network, or the system's connection manager runs the direct link itself. NetworkManager only keeps groups it negotiated itself, and it has no way to host a group that a phone joins with a password.

## 3. Everything we tried to keep the Wi-Fi connected

| # | Approach | Result |
|---|---|---|
| 1 | quickshare-direct's own helper (group through NetworkManager's wpa_supplicant) | NetworkManager removes the group; on a DFS network it also picked 5745 MHz |
| 2 | v1.1.0 fast mode: take the card from NetworkManager, host the group alone on 2.4 GHz | **Works.** The Wi-Fi pauses; about 5 MB/s |
| 3 | Group next to the connection, through NetworkManager's wpa_supplicant | NetworkManager removes it 0.2 ms after it starts |
| 4 | Take the card, then rejoin the same network on our own wpa_supplicant and host the group next to it | The rejoin stays in "scanning" although the network is in range. Unresolved; branch [`wip/keep-wifi`](https://github.com/Emanuel4100/omarchy-quickshare/tree/wip/keep-wifi), last attempt not tested (`sudo system/quickshare-fastlink --check`) |
| 5 | A second, private wpa_supplicant on its own interface | Impossible on the AX210 (see below) |
| 6 | Let NetworkManager adopt the group | Impossible (see below) |
| 7 | A plain hotspot next to the connection | The AX210 allows it only on the connection's channel, and 5 GHz is "no IR" |
| 8 | Patch NetworkManager so it keeps groups it didn't start | **Works** in a sandbox and on real hardware; slower, and one stall (section 4) |

**Why #5 is impossible on the AX210:**
- wpa_supplicant switches any interface it's given to normal client mode and brings it up (`driver_nl80211.c`, around line 3555). The card allows only one normal interface, and NetworkManager's is it.
- The single Wi-Fi Direct management interface is already held by NetworkManager's wpa_supplicant.

**Why #6 is impossible:** NetworkManager only adopts a group while it's connecting to one configured peer.
- It searches for that peer for 10 s, then fails.
- Once the group is up, it fails after 5 s if that peer hasn't joined.
- It would also start its own WPS pairing with the peer.

Phones use random Wi-Fi Direct addresses that appear only once they're joining, so no peer address can be configured in advance.

**Not tried yet:**

| Option | Effect |
|---|---|
| Ethernet on the desktop | The Wi-Fi card is free for transfers, and nothing is lost when it pauses |
| A USB Wi-Fi adapter just for Quick Share | Full speed, no pause |
| Transfers over the local network (`QSD_BWU=lan` in quickshare-direct) | Never touches the Wi-Fi, but only works when the phone is on the same network |
| Wi-Fi Aware (NAN), which the phones offer first | Linux NAN data path support is still unmerged patches (2026), and quickshare-direct doesn't speak it |

## 4. The NetworkManager patch

```diff
--- a/src/core/devices/wifi/nm-device-wifi-p2p.c
+++ b/src/core/devices/wifi/nm-device-wifi-p2p.c
@@ supplicant_iface_group_started_cb
     if (!nm_device_is_activating(NM_DEVICE(self))) {
         _LOGW(LOGD_DEVICE | LOGD_WIFI,
               "P2P: WPA supplicant notified a group start but we are not trying to connect! "
               "Ignoring the event.");
+        /* Someone else started this group (e.g. an autonomous group owner set up
+         * through wpa_supplicant directly). Let go of its interface without
+         * removing it from wpa_supplicant: when the last reference to it is
+         * dropped, disposing it would call RemoveInterface and tear the group
+         * down right after it came up. */
+        if (group_iface != iface
+            && nm_supplicant_interface_get_state(group_iface) != NM_SUPPLICANT_INTERFACE_STATE_DOWN)
+            _nm_supplicant_interface_set_state_down(group_iface,
+                                                    FALSE,
+                                                    "P2P group not started by NetworkManager");
         return;
     }
```

### Sandbox test

The test uses simulated radios (`mac80211_hwsim radios=3 channels=2 support_p2p_device=1`), each in its own network namespace, with a private D-Bus, wpa_supplicant and NetworkManager:

1. `ap` hosts a WPA2 network on 2412 MHz.
2. `pc` runs NetworkManager connected to it, and starts a group on 2437 MHz through NetworkManager's wpa_supplicant (D-Bus `GroupAdd`, like quickshare-direct).
3. `phone` joins the group with its passphrase.

| | Stock NetworkManager | Patched |
|---|---|---|
| Group | `AP-DISABLED` 0.7 ms after `P2P-GROUP-STARTED` | Stays up |
| Phone joins and pings across the group | No | Yes |
| PC stays connected to its network | Yes | Yes |

Gotchas in the sandbox setup:
- **udev and namespaces:** NetworkManager waits for udev to initialize each device when it thinks it runs in the first network namespace with a writable `/sys` (`nm_linux_platform_new`). udev never sees devices moved into a namespace, so they stay "unmanaged". The sandbox mounts `/sys` read-only, as containers do.
- **Lingering interface:** on simulated radios, a removed group's network interface lingers, so "alive" has to be checked in wpa_supplicant's interface list.

### Real hardware

**How it was swapped in:**
- The patched build used Arch's own build settings.
- It replaced the system's binary and Wi-Fi plugin through bind mounts, with nothing written to disk.
- If the Wi-Fi didn't come back within 45 s, it reverted at once; otherwise it reverted automatically after 20 minutes.
- Quick Share's group came from a helper that starts it through NetworkManager's wpa_supplicant on 2.4 GHz and leaves the connection alone.

**Transfers from the Galaxy S24 Ultra:**

| Mode | Size | Result | Speed | Wi-Fi |
|---|---|---|---|---|
| Stock NetworkManager, card taken over (v1.1.0 fast mode) | 79 MB | Done in about 15 s | ~5 MB/s | Paused |
| Patched NetworkManager, group next to the connection | 677 MB | Stalled at 136 MB after about 2 min | ~1.1 MB/s | Kept |
| Patched NetworkManager, group next to the connection | 269 MB | Done in about 155 s | ~1.7 MB/s | Kept |

In both runs with the patch, the phone joined the 2.4 GHz group (4–6 s after the offer), and the Wi-Fi on 5180 MHz stayed connected. "Sometimes fails" on the phone matches the stall. The likely suspect is the card alternating between the two channels (5180 MHz for the network, 2437 MHz for the group). Wi-Fi power save is already off (`wifi.powersave = 2`).

The patch, the sandbox, and the build and swap scripts are in [Emanuel4100/nm-p2p-group-fix](https://github.com/Emanuel4100/nm-p2p-group-fix) (private for now).

## 5. Next steps

- **Find out why the patched setup is slower and stalls.**
  - Repeat with the PC on a 2.4 GHz network. If the group shares the connection's channel and the stalls stop, the channel alternation is the cause.
  - During a stall, look at `iw dev p2p-wlp6s0-0 station dump` (retries, signal) and the wpa_supplicant and NetworkManager logs.
  - Check quickshare-direct's `Unhandled offline frame ... type 12`, logged around the stall.
- **Plugin:** start the group next to the connection first, and fall back to pausing the Wi-Fi when NetworkManager removes it. That works with stock and patched NetworkManager alike.
- **NetworkManager:** carry the patch as a local Arch package (Arch's PKGBUILD plus the patch; roll back with the cached stock package), and propose it upstream on NetworkManager's GitLab.
- **Sending:** confirm a PC → S24 transfer end to end. Report the missing beacon to quickshare-direct.
- **Receiver stopped by something else:** on 2026-11-04 at 00:50:37, a `systemctl --user` call from the desktop session stopped the receiver mid-transfer. The cause is unknown.

## Picking this up on another machine

```bash
omarchy plugin update emanuel.quickshare            # v1.2.0 and these notes
git clone https://github.com/Emanuel4100/omarchy-quickshare ~/Projects/omarchy-quickshare
git -C ~/Projects/omarchy-quickshare switch wip/keep-wifi   # only for approach #4
git clone git@github.com:Emanuel4100/nm-p2p-group-fix.git ~/Projects/nm-p2p-group-fix
```

Then follow that repo's README. Check the Wi-Fi card first (`iw phy`): hosting a group next to the
connection needs a combination with `P2P-GO` and `#channels <= 2`. Other cards may also mark
different channels "no IR".
