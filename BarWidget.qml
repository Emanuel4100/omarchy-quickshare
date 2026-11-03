import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Quick Share in the bar. quickshare-direct (a systemd user service) does the
// protocol; this widget only drives it through the bundled `quickshare` CLI.
//
// Receiving on/off comes from `quickshare status`. Incoming transfers are read
// live from the receiver's journal (progress: the growing files' size), and
// sends from the state file `quickshare send` keeps, whoever started them (the
// bar, the menu or the file manager).
BarWidget {
  id: root
  moduleName: "emanuel.quickshare"

  readonly property string helperPath: String(Qt.resolvedUrl("quickshare")).replace(/^file:\/\//, "")
  readonly property string installerPath: String(Qt.resolvedUrl("install.sh")).replace(/^file:\/\//, "")
  readonly property string sendStatePath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/quickshare/send.json"

  // Nerd Font (Material Design) glyphs, one per state.
  readonly property string glyphOff: String.fromCodePoint(0xf1514)      // share-variant-outline
  readonly property string glyphReady: String.fromCodePoint(0xf0497)    // share-variant
  readonly property string glyphIncoming: String.fromCodePoint(0xf01da) // download
  readonly property string glyphSending: String.fromCodePoint(0xf0552)  // upload
  readonly property string glyphDone: String.fromCodePoint(0xf012c)     // check
  readonly property string glyphFailed: String.fromCodePoint(0xf0156)   // close
  readonly property string glyph: root.flash === "done" ? glyphDone
    : root.flash === "failed" ? glyphFailed
    : root.sending ? glyphSending
    : root.incoming ? glyphIncoming
    : root.receiving ? glyphReady : glyphOff

  property bool installed: true
  property bool receiving: false
  property bool fast: false
  property bool incoming: false
  property var sendInfo: ({})
  readonly property bool sending: sendProc.running || (root.sendInfo.pid || 0) > 0
  readonly property bool busy: incoming || sending
  property string flash: ""

  // The incoming transfer: files being written, their total size, bytes so far, and the link.
  property var destinations: []
  property real totalBytes: 0
  property real receivedBytes: 0
  property real rate: 0
  property real lastSample: 0
  property string link: ""
  property bool upgradeOffered: false

  implicitWidth: button.implicitWidth
  implicitHeight: barSize

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function applyStatus(text) {
    var s
    try { s = JSON.parse(text) } catch (e) { return }
    root.installed = s.installed === true
    root.receiving = s.receiving === true
    root.fast = s.fast === true
    if (!root.receiving) root.incoming = false
    sendState.reload()
  }

  function applySend(text) {
    var s
    try { s = JSON.parse(text) } catch (e) { return }
    var was = root.sendInfo
    root.sendInfo = s
    // A send that just ended: flash its result (not an old one read at startup).
    if (s.result && s.at !== was.at && Date.now() / 1000 - s.at < 10) {
      if (s.result === "sent") showFlash("done")
      else if (s.result === "failed") showFlash("failed")
    }
  }

  function showFlash(kind) {
    root.flash = kind
    flashTimer.restart()
  }

  function send() {
    if (root.sending) Quickshell.execDetached([root.helperPath, "cancel"])
    else if (!sendProc.running) sendProc.running = true
  }

  // Not set up yet (added with `omarchy plugin add` only): run install.sh in a terminal.
  function runInstaller() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", root.installerPath])
  }

  function openMenu() {
    if (!menuProc.running) menuProc.running = true
  }

  // Lines from quickshare-direct's log that start, describe and end an incoming transfer.
  function onLogLine(line) {
    var m
    if (line.indexOf("RemoteDeviceInfo:") !== -1) {
      root.destinations = []
      root.totalBytes = 0
      root.receivedBytes = 0
      root.rate = 0
      root.link = ""
      root.upgradeOffered = false
    } else if ((m = line.match(/Destination: "(.*)"$/))) {
      root.destinations = root.destinations.concat([m[1].replace(/\\(["\\])/g, "$1")])
    } else if (line.indexOf("Asking for user consent") !== -1) {
      root.incoming = true
      if ((m = line.match(/total_bytes: (\d+)/))) root.totalBytes = Number(m[1])
    } else if (line.indexOf("BWU: offering") !== -1) {
      root.upgradeOffered = true
    } else if ((m = line.match(/BWU: upgraded to (.*?);/))) {
      root.link = m[1].indexOf("Wi-Fi Direct") !== -1 ? "Wi-Fi Direct"
        : m[1].indexOf("hotspot") !== -1 ? "a Wi-Fi hotspot" : "your Wi-Fi network"
    } else if (line.indexOf("Transfer finished") !== -1) {
      if (root.incoming) showFlash("done")
      root.incoming = false
    // The Bluetooth session also ends when the transfer moves to Wi-Fi; only without that it's over.
    } else if (line.indexOf("Transfer canceled") !== -1 || line.indexOf("declined") !== -1
               || (line.indexOf("session ended") !== -1 && !root.upgradeOffered)) {
      root.incoming = false
    } else if (line.indexOf("receiver '") !== -1 || line.indexOf("Stopping") !== -1) {
      debounce.restart()
    }
  }

  function onSizes(text) {
    var sum = 0
    text.split("\n").forEach(function(l) { if (l !== "") sum += Number(l) || 0 })
    var now = Date.now()
    if (root.lastSample > 0 && sum >= root.receivedBytes) {
      var r = (sum - root.receivedBytes) * 1000 / (now - root.lastSample)
      root.rate = root.rate > 0 ? root.rate * 0.6 + r * 0.4 : r
    }
    root.receivedBytes = sum
    root.lastSample = now
  }

  function human(bytes) {
    var units = ["B", "KB", "MB", "GB"], i = 0
    while (bytes >= 1024 && i < units.length - 1) { bytes /= 1024; i++ }
    return (i === 0 ? bytes : bytes.toFixed(1)) + " " + units[i]
  }

  function incomingText() {
    var name = root.destinations.length === 1 ? root.destinations[0].replace(/^.*\//, "")
      : root.destinations.length + " files"
    var parts = ["Receiving " + name]
    if (root.totalBytes > 0 && root.receivedBytes > 0)
      parts.push(Math.min(100, Math.floor(root.receivedBytes * 100 / root.totalBytes)) + "% of " + human(root.totalBytes))
    if (root.rate > 0) parts.push(human(root.rate) + "/s")
    var head = parts.join(" · ")
    if (root.receivedBytes > 0) head += "\nvia " + (root.link || "Bluetooth (slow)")
    return head
  }

  function tooltip() {
    if (!root.installed) return "Quick Share isn't set up yet\nClick to install"
    var head = root.sending ? (root.sendInfo.title || "Sending…") + (root.sendInfo.detail ? "\n" + root.sendInfo.detail : "")
      : root.incoming ? incomingText()
      : root.receiving ? "Quick Share: this PC can receive" : "Quick Share: receiving is off"
    var click = root.sending ? "Click: cancel sending" : "Click: send a file"
    return head + (root.fast && !root.busy ? "\nFast Wi-Fi on" : "")
      + "\n" + click + " · Middle: open Downloads · Right: menu"
  }

  Component.onCompleted: refresh()

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    fontSize: Style.bar.iconFont
    foreground: root.installed && (root.receiving || root.sending) && root.bar ? root.bar.barForeground : Color.muted
    active: root.busy
    tooltipText: root.tooltip()
    onPressed: function(buttonCode) {
      if (!root.installed) root.runInstaller()
      else if (buttonCode === Qt.RightButton) root.openMenu()
      else if (buttonCode === Qt.MiddleButton) Quickshell.execDetached([root.helperPath, "downloads"])
      else root.send()
    }
  }

  Process {
    id: statusProc
    command: [root.helperPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: sendProc
    command: [root.helperPath, "send"]
    onExited: sendState.reload()
  }

  Process {
    id: menuProc
    command: [root.helperPath, "menu"]
    onExited: root.refresh()
  }

  // `quickshare status` creates it, so it exists before it's watched.
  FileView {
    id: sendState
    path: root.sendStatePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applySend(text())
  }

  Process {
    id: logProc
    running: true
    command: ["journalctl", "--user", "--unit", "quickshare-direct.service", "--follow", "--lines", "0", "--output", "cat"]
    stdout: SplitParser { onRead: function(line) { root.onLogLine(String(line || "")) } }
    onExited: logRestart.start()
  }

  // Sizes of the files being received, once a second (missing ones aren't created yet).
  Process {
    id: sizeProc
    command: ["stat", "-c", "%s", "--"].concat(root.destinations)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSizes(text)
    }
  }
  Timer {
    interval: 1000
    repeat: true
    running: root.incoming && root.destinations.length > 0
    onTriggered: if (!sizeProc.running) sizeProc.running = true
    onRunningChanged: if (running) root.lastSample = 0
  }

  Timer { id: flashTimer; interval: 3000; onTriggered: root.flash = "" }
  Timer { id: debounce; interval: 500; onTriggered: root.refresh() }
  Timer { id: logRestart; interval: 5000; onTriggered: logProc.running = true }
  // Faster while not set up, so the icon comes alive soon after install.sh finishes.
  Timer { interval: root.installed ? 30000 : 5000; running: true; repeat: true; onTriggered: root.refresh() }
}
