#!/usr/bin/env bash
# Quick Share for Omarchy: one-shot setup.
#
#   curl -fsSL https://raw.githubusercontent.com/Emanuel4100/omarchy-quickshare/main/install.sh | bash
#   ~/.config/omarchy/plugins/emanuel.quickshare/install.sh [--uninstall]
#
# Adds the plugin (when run through curl), installs quickshare-direct from its latest release
# (checksum-verified), opens its ports in ufw/firewalld, sets the Wi-Fi region if none is set,
# routes the receiver's Accept/Decline prompts through bin/notify-send, links the `quickshare`
# CLI into ~/.local/bin, starts receiving and puts the icon on the bar. Run it again any time:
# steps that are already done are skipped.
#
# Environment: QS_REPO (plugin git URL), QS_YES=1 (ask nothing: skip the Wi-Fi region and fast mode)
set -euo pipefail

ID=emanuel.quickshare
REPO=${QS_REPO:-https://github.com/Emanuel4100/omarchy-quickshare.git}
QSD_REPO=papshmeare/quickshare-direct
PLUGIN_DIR=$HOME/.config/omarchy/plugins/$ID
OMARCHY_BIN=${OMARCHY_PATH:-/usr/share/omarchy}/bin
ENV_FILE=$HOME/.config/quickshare-direct/env
CLI_LINK=$HOME/.local/bin/quickshare
ICON_FILE=$HOME/.local/share/icons/hicolor/scalable/apps/omarchy-quickshare.svg
REGDOM_FILE=/etc/conf.d/wireless-regdom
UNIT=quickshare-direct.service
export PATH="$OMARCHY_BIN:$HOME/.local/bin:$PATH"

if [[ -t 1 ]]; then
  bold=$'\e[1m' green=$'\e[32m' yellow=$'\e[33m' red=$'\e[31m' reset=$'\e[0m'
else
  bold='' green='' yellow='' red='' reset=''
fi
step() { printf '\n%s==>%s %s\n' "$bold" "$reset" "$*"; }
ok() { printf '  %s✓%s %s\n' "$green" "$reset" "$*"; }
note() { printf '  %s!%s %s\n' "$yellow" "$reset" "$*"; }
die() { printf '%serror:%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

# The name phones see: QSD_NAME from the receiver's env file, else the host name.
device_name() { sed -n 's/^QSD_NAME=//p' "$ENV_FILE" 2>/dev/null | tail -1 | grep . || uname -n; }

interactive() { [[ -t 0 && -t 1 && -z ${QS_YES:-} ]]; }
confirm() { interactive && gum confirm "$@"; }

# curl | bash, or a copy outside the plugin folder: add the plugin, then run its own install.sh
# with the terminal as stdin (the pipe is the script itself, so prompts can't read from it).
bootstrap() {
  command -v omarchy >/dev/null || die "this is an Omarchy plugin; Omarchy wasn't found (https://omarchy.org)"
  if [[ -f $PLUGIN_DIR/manifest.json ]]; then
    ok "plugin already added: $PLUGIN_DIR"
  elif [[ ${1:-} == --uninstall ]]; then
    die "$ID isn't installed"
  else
    step "Adding the plugin"
    omarchy plugin add "$REPO" --yes
  fi
  if [[ ! -x $PLUGIN_DIR/install.sh ]]; then
    [[ -d $PLUGIN_DIR/.git ]] || die "$PLUGIN_DIR has no install.sh; remove it and run this again"
    step "Updating the plugin (this copy predates install.sh)"
    omarchy plugin update "$ID" --yes
  fi
  if [[ -t 0 ]]; then
    exec "$PLUGIN_DIR/install.sh" "$@"
  elif (: </dev/tty) 2>/dev/null; then
    exec "$PLUGIN_DIR/install.sh" "$@" </dev/tty
  else
    QS_YES=1 exec "$PLUGIN_DIR/install.sh" "$@" </dev/null
  fi
}

pkg_arch() {
  case $(uname -m) in
    x86_64) echo x86_64 ;;
    aarch64) echo aarch64 ;;
    *) die "quickshare-direct has packages for x86_64 and aarch64 only, not $(uname -m)" ;;
  esac
}

# Latest quickshare-direct release tag (e.g. qsd-v0.1.5), from where /releases/latest redirects.
latest_tag() {
  curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$QSD_REPO/releases/latest" 2>/dev/null |
    sed -n 's|.*/releases/tag/||p'
}

FRESH=0
install_quickshare_direct() {
  step "quickshare-direct (the Quick Share receiver)"
  local have tag want file tmp
  have=$(pacman -Q quickshare-direct 2>/dev/null | awk '{print $2}') || true
  if [[ -z $have ]] && command -v quickshare-direct >/dev/null; then
    ok "installed outside pacman ($(command -v quickshare-direct)); leaving it alone"
    return
  fi
  tag=$(latest_tag) || true
  want=${tag#qsd-v}
  if [[ -z $tag ]]; then
    [[ -n $have ]] || die "couldn't reach github.com to download quickshare-direct"
    note "couldn't check for a newer release; keeping $have"
    return
  fi
  if [[ -n $have ]] && (( $(vercmp "${have%-*}" "$want") >= 0 )); then
    ok "installed: $have"
    return
  fi

  file=quickshare-direct-$(pkg_arch).pkg.tar.zst
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: $tmp is local
  trap "rm -rf '$tmp'" EXIT
  echo "  downloading $file ($tag)"
  curl -fL --retry 3 --progress-bar -o "$tmp/$file" "https://github.com/$QSD_REPO/releases/download/$tag/$file"
  curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" "https://github.com/$QSD_REPO/releases/download/$tag/SHA256SUMS"
  (cd "$tmp" && sha256sum --check --ignore-missing --quiet SHA256SUMS) || die "$file doesn't match the release's SHA256SUMS"
  ok "checksum matches"
  sudo pacman -U --needed --noconfirm "$tmp/$file"
  ok "installed ${have:+$have → }$want"
  FRESH=1
}

open_firewall() {
  step "Firewall"
  if command -v ufw >/dev/null && systemctl is-active -q ufw; then
    # App rules are recorded by name in user.rules, which is world-readable.
    if grep -q 'quickshare-direct' /etc/ufw/user.rules 2>/dev/null; then
      ok "ufw already allows quickshare-direct"
    else
      sudo ufw allow quickshare-direct >/dev/null
      ok "ufw: allowed quickshare-direct (TCP 46257-46258)"
    fi
  elif command -v firewall-cmd >/dev/null && systemctl is-active -q firewalld; then
    if sudo firewall-cmd -q --query-service=quickshare-direct --permanent; then
      ok "firewalld already allows quickshare-direct"
    else
      sudo firewall-cmd -q --permanent --add-service=quickshare-direct && sudo firewall-cmd -q --reload
      ok "firewalld: allowed quickshare-direct"
    fi
  else
    ok "no active firewall"
  fi
}

# The country of the system timezone, as a regulatory domain guess (Israel → Asia/Jerusalem → IL).
timezone_country() {
  local tz canon
  tz=$(timedatectl show -p Timezone --value 2>/dev/null) || return 0
  canon=$(awk -v z="$tz" '$1 == "L" && $3 == z { print $2; exit }' /usr/share/zoneinfo/tzdata.zi 2>/dev/null) || true
  awk -F'\t' -v z="${canon:-$tz}" '$3 == z { print $1; exit }' /usr/share/zoneinfo/zone.tab 2>/dev/null || true
}

set_wifi_region() {
  step "Wi-Fi region"
  local cc
  cc=$(iw reg get 2>/dev/null | awk '/^global/ { g = 1; next } g && /^country/ { sub(":", "", $2); print $2; exit }') || true
  if [[ -n $cc && $cc != 00 ]]; then
    ok "set to $cc"
    return
  fi
  if ! interactive; then
    note "not set, so direct Wi-Fi links can't use 5 GHz; run install.sh in a terminal to set it"
    return
  fi
  echo "  Not set (country 00), so the direct Wi-Fi link can't use 5 GHz."
  cc=$(gum input --header "Your country's 2-letter code (empty to skip)" --value "$(timezone_country)" --char-limit 2) || true
  cc=${cc^^}
  if [[ -z $cc ]]; then
    note "skipped"
    return
  fi
  [[ $cc =~ ^[A-Z]{2}$ ]] || die "'$cc' isn't a 2-letter country code"
  sudo iw reg set "$cc"
  if grep -q "^#\?WIRELESS_REGDOM=\"$cc\"" "$REGDOM_FILE" 2>/dev/null; then
    sudo sed -i -e 's/^WIRELESS_REGDOM=/#&/' -e "s/^#WIRELESS_REGDOM=\"$cc\"/WIRELESS_REGDOM=\"$cc\"/" "$REGDOM_FILE"
    ok "set to $cc (saved in $REGDOM_FILE)"
  else
    note "set to $cc until reboot ($REGDOM_FILE has no entry for it)"
  fi
}

# quickshare-direct asks Accept/Decline through notify-send; our shim must come first on the
# receiver's PATH (systemd reads this file as-is, so the paths are written out in full). The shim
# gives every notification our icon, by its icon-theme name.
ENV_CHANGED=0
route_prompts() {
  step "Notifications"
  if cmp -s "$PLUGIN_DIR/assets/quickshare.svg" "$ICON_FILE"; then
    ok "icon installed"
  else
    mkdir -p "${ICON_FILE%/*}"
    cp "$PLUGIN_DIR/assets/quickshare.svg" "$ICON_FILE"
    ok "icon installed ($ICON_FILE)"
  fi
  local want rest
  want="PATH=$(readlink -f "$PLUGIN_DIR")/bin:$OMARCHY_BIN:$HOME/.local/bin:/usr/local/bin:/usr/bin"
  if grep -qxF "$want" "$ENV_FILE" 2>/dev/null && (( $(grep -c '^PATH=' "$ENV_FILE") == 1 )); then
    ok "Accept/Decline open as an Omarchy menu"
    return
  fi
  mkdir -p "${ENV_FILE%/*}"
  rest=$(grep -v '^PATH=' "$ENV_FILE" 2>/dev/null || true)
  printf '%s\n' ${rest:+"$rest"} "$want" > "$ENV_FILE"
  ok "Accept/Decline open as an Omarchy menu ($ENV_FILE)"
  ENV_CHANGED=1
}

link_cli() {
  step "quickshare command"
  local target
  target=$(readlink -f "$PLUGIN_DIR")/quickshare
  if [[ $(readlink -f "$CLI_LINK" 2>/dev/null) == "$target" ]]; then
    ok "$CLI_LINK"
  elif [[ -e $CLI_LINK && ! -L $CLI_LINK ]]; then
    note "$CLI_LINK exists and isn't a link to this plugin; leaving it"
  else
    mkdir -p "${CLI_LINK%/*}"
    ln -sfn "$target" "$CLI_LINK"
    ok "linked $CLI_LINK"
  fi
}

start_receiver() {
  step "Receiving"
  systemctl --user daemon-reload
  if ! systemctl --user is-active -q "$UNIT"; then
    systemctl --user enable --now "$UNIT"
    ok "on: phones can now pick $(device_name)"
  elif (( ENV_CHANGED )); then
    systemctl --user restart "$UNIT"
    ok "on (restarted to pick up the prompt routing)"
  else
    ok "on"
  fi
}

add_to_bar() {
  step "Bar icon"
  if omarchy plugin list --json | jq -e --arg id "$ID" 'any(.[]; .id == $id and .enabled)' >/dev/null; then
    ok "on the bar"
  else
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    omarchy plugin enable "$ID" >/dev/null
    ok "added to the bar"
  fi
}

offer_fast_mode() {
  step "Fast Wi-Fi transfers"
  if [[ -e /etc/systemd/system/quickshare-ap@.service.d/50-omarchy-fastlink.conf ]]; then
    ok "on"
    return
  fi
  if (( FRESH )) && [[ $(iw phy 2>/dev/null) == *P2P-GO* ]] &&
    confirm --default=false "Turn on fast Wi-Fi transfers? This PC's Wi-Fi pauses while a file transfers (see the README)."; then
    "$PLUGIN_DIR/quickshare" fast on
  else
    ok "off: transfers use Bluetooth (turn on any time: quickshare fast on)"
  fi
}

do_install() {
  [[ $EUID -ne 0 ]] || die "run this as your normal user, not root; it uses sudo where it has to"
  command -v omarchy-shell >/dev/null || die "this is an Omarchy plugin; Omarchy wasn't found (https://omarchy.org)"
  pkg_arch >/dev/null
  printf '%sQuick Share for Omarchy%s\n' "$bold" "$reset"

  install_quickshare_direct
  open_firewall
  set_wifi_region
  route_prompts
  link_cli
  start_receiver
  add_to_bar
  offer_fast_mode

  step "Checking the setup"
  "$PLUGIN_DIR/quickshare" doctor || true
  printf '\n%sDone.%s On your phone: Share → Quick Share → pick %s%s%s.\n' "$bold" "$reset" "$bold" "$(device_name)" "$reset"
  echo "To send, click the bar icon (the phone must be on its Quick Share receive screen)."
}

uninstall() {
  printf '%sRemoving Quick Share for Omarchy%s\n' "$bold" "$reset"
  [[ -e /etc/systemd/system/quickshare-ap@.service.d/50-omarchy-fastlink.conf ]] && "$PLUGIN_DIR/quickshare" fast off
  if systemctl --user cat "$UNIT" >/dev/null 2>&1; then
    systemctl --user disable --now "$UNIT" 2>/dev/null || true
    ok "receiving off"
  fi
  if [[ -f $ENV_FILE ]] && grep -q "^PATH=$(readlink -f "$PLUGIN_DIR")/bin:" "$ENV_FILE"; then
    sed -i '\|^PATH='"$(readlink -f "$PLUGIN_DIR")"'/bin:|d' "$ENV_FILE"
    [[ -s $ENV_FILE ]] || { rm -f "$ENV_FILE"; rmdir --ignore-fail-on-non-empty "${ENV_FILE%/*}"; }
    ok "prompt routing removed from $ENV_FILE"
  fi
  rm -f "$ICON_FILE"
  if [[ -L $CLI_LINK && $(readlink -f "$CLI_LINK") == "$(readlink -f "$PLUGIN_DIR")/quickshare" ]]; then
    rm -f "$CLI_LINK"
    ok "removed $CLI_LINK"
  fi
  if pacman -Q quickshare-direct >/dev/null 2>&1 &&
    confirm --default=false "Also uninstall the quickshare-direct package (and its firewall rule)?"; then
    if command -v ufw >/dev/null && grep -q 'quickshare-direct' /etc/ufw/user.rules 2>/dev/null; then
      sudo ufw delete allow quickshare-direct >/dev/null && ok "ufw rule removed"
    fi
    sudo pacman -R --noconfirm quickshare-direct
    ok "quickshare-direct uninstalled"
  elif pacman -Q quickshare-direct >/dev/null 2>&1; then
    note "quickshare-direct stays installed (remove it with: sudo pacman -R quickshare-direct)"
  fi
  exec omarchy plugin remove "$ID" --yes
}

usage() {
  cat <<'USAGE'
Quick Share for Omarchy: set up (or remove) the plugin, quickshare-direct and the bar icon.

  install.sh               install, or finish/repair an install (safe to run again)
  install.sh --uninstall   remove the plugin; asks before removing quickshare-direct too

Environment: QS_YES=1 asks nothing; QS_REPO=<git url> adds the plugin from another repo.
USAGE
}

main() {
  case ${1:-} in
    "" | --uninstall) ;;
    -h | --help) usage; return ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  if [[ $(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null) != "$(readlink -f "$PLUGIN_DIR/install.sh" 2>/dev/null)" ]]; then
    bootstrap "$@"
  fi
  if [[ ${1:-} == --uninstall ]]; then uninstall; else do_install; fi
}

# On one line: with curl | bash, bash reads the script from the pipe as it runs.
main "$@"; exit
