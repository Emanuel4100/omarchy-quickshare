import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Quick Share in the bar. quickshare-direct (a systemd user service) does the
// protocol; this widget only drives it through the bundled `quickshare` CLI.
//
// Receiving on/off comes from `quickshare status`. Transfers in progress are
// read live from the receiver's journal, so the icon lights up while a device
// is sending, and while our own `quickshare send` runs.
BarWidget {
  id: root
  moduleName: "emanuel.quickshare"

  readonly property string helperPath: String(Qt.resolvedUrl("quickshare")).replace(/^file:\/\//, "")
  readonly property string installerPath: String(Qt.resolvedUrl("install.sh")).replace(/^file:\/\//, "")

  // Nerd Font (Material Design) glyphs, one per state.
  readonly property string glyphOff: String.fromCodePoint(0xf1514)      // share-variant-outline
  readonly property string glyphReady: String.fromCodePoint(0xf0497)    // share-variant
  readonly property string glyphIncoming: String.fromCodePoint(0xf01da) // download
  readonly property string glyphSending: String.fromCodePoint(0xf0552)  // upload
  readonly property string glyph: root.sending ? glyphSending
    : root.incoming ? glyphIncoming
    : root.receiving ? glyphReady : glyphOff

  property bool installed: true
  property bool receiving: false
  property bool fast: false
  property bool incoming: false
  readonly property bool sending: sendProc.running
  readonly property bool busy: incoming || sending

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
  }

  function send() {
    if (!sendProc.running) sendProc.running = true
  }

  // Not set up yet (added with `omarchy plugin add` only): run install.sh in a terminal.
  function runInstaller() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", root.installerPath])
  }

  function openMenu() {
    if (!menuProc.running) menuProc.running = true
  }

  // Lines from quickshare-direct's log that start and end an incoming transfer.
  function onLogLine(line) {
    if (line.indexOf("Asking for user consent") !== -1) root.incoming = true
    else if (line.indexOf("Transfer finished") !== -1 || line.indexOf("Transfer canceled") !== -1
             || line.indexOf("declined") !== -1 || line.indexOf("session ended") !== -1) root.incoming = false
    else if (line.indexOf("receiver '") !== -1 || line.indexOf("Stopping") !== -1) debounce.restart()
  }

  function tooltip() {
    if (!root.installed) return "Quick Share isn't set up yet\nClick to install"
    var head = root.sending ? "Sending…"
      : root.incoming ? "Receiving a file…"
      : root.receiving ? "Quick Share: this PC can receive" : "Quick Share: receiving is off"
    return head + (root.fast ? "\nFast Wi-Fi on (Wi-Fi pauses during transfers)" : "")
      + "\nClick: send a file · Middle: open Downloads · Right: menu"
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
  }

  Process {
    id: menuProc
    command: [root.helperPath, "menu"]
    onExited: root.refresh()
  }

  Process {
    id: logProc
    running: true
    command: ["journalctl", "--user", "--unit", "quickshare-direct.service", "--follow", "--lines", "0", "--output", "cat"]
    stdout: SplitParser { onRead: function(line) { root.onLogLine(String(line || "")) } }
    onExited: logRestart.start()
  }

  Timer { id: debounce; interval: 500; onTriggered: root.refresh() }
  Timer { id: logRestart; interval: 5000; onTriggered: logProc.running = true }
  // Faster while not set up, so the icon comes alive soon after install.sh finishes.
  Timer { interval: root.installed ? 30000 : 5000; running: true; repeat: true; onTriggered: root.refresh() }
}
