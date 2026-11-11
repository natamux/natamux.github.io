#!/bin/sh
# Installs or updates the Natamux desktop app on macOS, Debian and Ubuntu.
# Usage: curl -fsSL https://natamux.github.io/install.sh | sh
# Windows: irm https://natamux.github.io/install.ps1 | iex
# Source: https://github.com/lenhatthanh20/natamux/blob/main/site/public/install.sh
set -eu

REPO=https://github.com/lenhatthanh20/natamux
GUIDE=https://natamux.github.io/docs/getting-started/install/
# The same key as RELEASE_SIGNER in crates/natamux-update/src/signature.rs.
SIGNER=RWSgtwsXHppEP5n4kgg1Q3yNIYODQNGsMQBKF93tjSRwzL1BrjeGoBpo

say() { printf '%s\n' "$*"; }
fail() {
  printf 'Natamux install: %s\n' "$*" >&2
  exit 1
}

fetch() { curl -fsSL --proto '=https' --tlsv1.2 "$@"; }

# valid_tag <tag>: a stable release tag such as v1.2.3.
valid_tag() {
  case $1 in *'
'*) return 1 ;; esac
  printf '%s\n' "$1" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+'
}

# latest_tag: the tag /releases/latest redirects to. One tag for every file, so a release
# published during the run cannot mix two versions.
latest_tag() {
  url=$(fetch -I -o /dev/null -w '%{url_effective}' "$REPO/releases/latest") ||
    fail "cannot reach GitHub."
  printf '%s\n' "${url##*/}"
}

# sum_for <file name> <SHA256SUMS.txt>: the expected hash, empty when the file has no line.
sum_for() { awk -v f="$1" '$2 == f || $2 == "*" f { print $1; exit }' "$2"; }

file_sum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

verify_sum() {
  name=${1##*/}
  want=$(sum_for "$name" "$2")
  [ -n "$want" ] || fail "SHA256SUMS.txt has no line for $name."
  [ "$(file_sum "$1")" = "$want" ] || fail "$name does not match SHA256SUMS.txt. Nothing was installed."
}

# trusted_ok <minisign output> <tag>: the release key signed exactly this version.
trusted_ok() { printf '%s\n' "$1" | grep -Fqx "Trusted comment: natamux $2"; }

verify_signature() {
  out=$(minisign -Vm "$1" -x "$2" -P "$SIGNER" 2>&1) ||
    fail "the signature of SHA256SUMS.txt is not valid. Nothing was installed. $out"
  trusted_ok "$out" "$tag" ||
    fail "SHA256SUMS.txt is signed for another version, not $tag. Nothing was installed."
}

# get_release <file> <minisign install hint>: downloads the file of the latest release
# into $tmp and checks it.
get_release() {
  tag=$(latest_tag)
  valid_tag "$tag" || fail "unexpected release tag '$tag'."
  base=$REPO/releases/download/$tag
  say "Downloading $1 of Natamux $tag..."
  fetch -o "$tmp/$1" "$base/$1" || fail "cannot download $base/$1."
  fetch -o "$tmp/SHA256SUMS.txt" "$base/SHA256SUMS.txt" || fail "cannot download SHA256SUMS.txt."
  if command -v minisign >/dev/null 2>&1; then
    fetch -o "$tmp/SHA256SUMS.txt.minisig" "$base/SHA256SUMS.txt.minisig" ||
      fail "cannot download SHA256SUMS.txt.minisig."
    verify_signature "$tmp/SHA256SUMS.txt" "$tmp/SHA256SUMS.txt.minisig"
    say "Signature checked."
  else
    say "Warning: the release signature was not checked, because minisign is not installed ($2)."
  fi
  verify_sum "$tmp/$1" "$tmp/SHA256SUMS.txt"
  say "Checksum checked."
}

app_running() { pgrep -x natamux-app >/dev/null 2>&1; }

# mac_file <uname -m> <sysctl.proc_translated>: a shell under Rosetta says x86_64 on Apple silicon.
mac_file() {
  case $1 in
    arm64) say Natamux-mac-arm64.dmg ;;
    x86_64) if [ "$2" = 1 ]; then say Natamux-mac-arm64.dmg; else say Natamux-mac-x64.dmg; fi ;;
    *) return 1 ;;
  esac
}

# LSMinimumSystemVersion in crates/natamux-app/resources/Info.plist.
mac_version_ok() {
  major=${1%%.*}
  case $major in '' | *[!0-9]*) return 1 ;; esac
  [ "$major" -ge 11 ]
}

install_mac() {
  version=$(sw_vers -productVersion)
  mac_version_ok "$version" || fail "Natamux needs macOS 11 or later. This Mac has $version."
  translated=$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)
  file=$(mac_file "$(uname -m)" "$translated") || fail "unknown Mac processor $(uname -m)."
  get_release "$file" "brew install minisign"
  mnt=$tmp/mnt
  hdiutil attach -nobrowse -readonly -noautoopen -quiet -mountpoint "$mnt" "$tmp/$file" ||
    fail "cannot open $file."
  target=/Applications
  if [ ! -w "$target" ]; then
    target=$HOME/Applications
    mkdir -p "$target"
  fi
  app=$target/Natamux.app
  # Copy first, so a failed copy keeps the old app.
  rm -rf "$app.new"
  ditto "$mnt/Natamux.app" "$app.new" || fail "cannot copy Natamux.app to $target."
  rm -rf "$app"
  mv "$app.new" "$app"
  hdiutil detach -quiet "$mnt" && mnt=
  # The app is not signed with an Apple certificate yet; without this, macOS blocks the first start.
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
  say "Natamux $tag is installed in $app."
  say "Open it with: open \"$app\""
}

# libc_needed <Depends field>: the glibc version the package needs.
libc_needed() { printf '%s\n' "$1" | sed -n 's/.*libc6 (>= \([^)]*\)).*/\1/p'; }

install_linux() {
  [ "$(uname -m)" = x86_64 ] || fail "Natamux for Linux runs on x86_64 only. This machine is $(uname -m)."
  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
    fail "this script installs the .deb package on Debian and Ubuntu. On other systems, use the AppImage: $REPO/releases/latest/download/Natamux-linux-x86_64.AppImage"
  fi
  if [ "$(id -u)" != 0 ] && ! command -v sudo >/dev/null 2>&1; then
    fail "run this script as root, or install sudo."
  fi
  file=Natamux-linux-amd64.deb
  get_release "$file" "sudo apt install minisign"
  need=$(libc_needed "$(dpkg-deb -f "$tmp/$file" Depends)")
  # shellcheck disable=SC2016 # ${Version} is a dpkg-query field, not a shell variable.
  have=$(dpkg-query -W -f='${Version}' libc6 2>/dev/null || true)
  if [ -n "$need" ] && [ -n "$have" ] && ! dpkg --compare-versions "$have" ge "$need"; then
    fail "Natamux needs glibc $need or later. This system has $have."
  fi
  # apt reads the package as the _apt user, which cannot open a mktemp folder.
  chmod 755 "$tmp"
  if [ "$(id -u)" = 0 ]; then
    apt-get install -y "$tmp/$file"
  else
    sudo apt-get install -y "$tmp/$file"
  fi
  say "Natamux $tag is installed in /opt/Natamux. Start it from the app menu or with /opt/Natamux/natamux-app."
}

cleanup() {
  if [ -n "${mnt:-}" ]; then hdiutil detach -quiet -force "$mnt" 2>/dev/null || true; fi
  if [ -n "${tmp:-}" ]; then rm -rf "$tmp"; fi
}

main() {
  command -v curl >/dev/null 2>&1 || fail "curl is missing."
  case $(uname -s) in
    Darwin) os=mac ;;
    Linux) os=linux ;;
    MINGW* | MSYS* | CYGWIN*) fail "on Windows, run this in PowerShell: irm https://natamux.github.io/install.ps1 | iex" ;;
    *) fail "this system is not supported. See $GUIDE" ;;
  esac
  if app_running; then fail "quit Natamux, then run the command again."; fi
  tmp=$(mktemp -d)
  trap cleanup EXIT
  trap 'exit 1' INT TERM
  case $os in
    mac) install_mac ;;
    linux) install_linux ;;
  esac
}

# All code above is functions, so a download cut short runs nothing.
[ -n "${NATAMUX_INSTALL_TEST:-}" ] || main "$@"
