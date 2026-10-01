#!/bin/sh
# Protection router agent: one-step install. Paste the line the Protection app
# shows (Add a device > Router) into the router's SSH shell. It looks like:
#
#   (curl -fsSL https://raw.githubusercontent.com/protection-dev/protection-releases/main/router/install.sh || wget -qO- https://raw.githubusercontent.com/protection-dev/protection-releases/main/router/install.sh) | sh -s -- 123456 my-project AIza...
#
# curl on Asuswrt-Merlin, wget (uclient-fetch) on OpenWrt; the line tries both.
# This only downloads the agent and hands over to `protection-agent setup`, which
# installs curl if it is missing, installs itself, enrols the router with the
# pairing code, and starts it. PROJECT and KEY are the app's own public Firebase
# client settings; the app puts them in the line.

CODE=$1
PROJECT=$2
KEY=$3
BASE=${PA_BASE:-https://raw.githubusercontent.com/protection-dev/protection-releases/main/router}

case $CODE in
  [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *)
    echo "Usage: sh install.sh <6-digit pairing code> <firebase project> <firebase key>" >&2
    echo "Copy the whole line from the Protection app: Add a device > Router." >&2
    exit 1
    ;;
esac
case $PROJECT in
  '' | *[!a-z0-9-]*)
    echo "The Firebase project is missing. Copy the whole line from the app again." >&2
    exit 1
    ;;
esac
case $KEY in
  '' | *[!A-Za-z0-9_-]*)
    echo "The Firebase key is missing. Copy the whole line from the app again." >&2
    exit 1
    ;;
esac

TMP=/tmp/protection-agent.install.$$
trap 'rm -f "$TMP"' EXIT INT TERM

# Looks a program up on PATH by hand: some routers' BusyBox is built without the
# `command` builtin (Asuswrt-Merlin on an RT-N18U), where `command -v` always fails.
have() {
  have_ifs=$IFS
  IFS=:
  for have_dir in $PATH; do
    if [ -n "$have_dir" ] && [ -f "$have_dir/$1" ] && [ -x "$have_dir/$1" ]; then
      IFS=$have_ifs
      return 0
    fi
  done
  IFS=$have_ifs
  return 1
}

fetch() {
  if have curl; then
    curl -fsSL --connect-timeout 10 --max-time 90 -o "$2" "$1"
  elif have uclient-fetch; then
    uclient-fetch -q -T 90 -O "$2" "$1"
  elif have wget; then
    wget -q -T 90 -O "$2" "$1"
  else
    echo "No curl, uclient-fetch or wget on this router." >&2
    return 1
  fi
}

echo "Downloading the Protection agent..."
if ! fetch "$BASE/protection-agent.sh" "$TMP"; then
  echo "Could not download the agent. Check the router's internet connection." >&2
  exit 1
fi

# A captive portal or an error page must never be run as root.
if ! head -n 1 "$TMP" | grep -q '^#!/bin/sh' || ! grep -q '^PA_AGENT_VERSION=' "$TMP"; then
  echo "The download was not the agent (a proxy or captive portal in the way?)." >&2
  exit 1
fi

sh "$TMP" setup "$CODE" "$PROJECT" "$KEY"
