#!/bin/sh
# protection-agent: reports an Asuswrt-Merlin or OpenWrt router to the Protection
# owner app, straight to Firebase. See docs/ROUTER-AGENT.md for the whole contract.
#
#   protection-agent setup CODE PROJECT KEY   install, enrol with a pairing code, start
#   protection-agent start | stop             the background service
#   protection-agent status                   enrolment, service and positioning state
#   protection-agent report                   print the report it would write (nothing sent)
#   protection-agent wifipos off | on         stop (or resume) Wi-Fi positioning
#   protection-agent doctor                   what this router lets the agent measure
#   protection-agent update                   sync the agent with the one on GitHub
#   protection-agent uninstall                stop and remove everything it installed
#
# Written for BusyBox ash and BusyBox awk: POSIX only, no bashisms. It sleeps
# between contacts, reads /proc and /sys with shell builtins, and does its parsing
# in one awk pass per report (plus one over the connection table per contact, for
# the data wired devices use). It signs in to Firebase anonymously, the way the
# Windows client does, and Firestore's rules let it write nothing but its own
# device document. PROJECT and KEY are the app's own public Firebase client
# settings. It needs curl, which setup installs on OpenWrt when it is missing.
#
# Test hooks: PA_ROOT prefixes every filesystem path it reads or writes,
# PA_SOURCED=1 loads the functions without running anything, PA_FAKE_EPOCH pins
# the wall clock, and PA_SCAN_WAIT is how long a Merlin Wi-Fi scan is given.

PA_AGENT_VERSION="1.8.2 (17)"
PA_ROOT="${PA_ROOT:-}"

# Cadence, in seconds. One read of its own document per contact, one write per
# full report: about 1,400 reads and 290 writes a day while idle.
PA_FULL_INTERVAL=300
PA_IDLE_INTERVAL=60
# While the owner has the router's page open (ownerActiveAt this recent), a full
# report every PA_HOT_INTERVAL. Matches the window a PC's poll loop uses.
PA_HOT_INTERVAL=10
PA_HOT_WINDOW=120
PA_PENDING_INTERVAL=30
PA_DORMANT_INTERVAL=3600
# An owner Refresh is answered while it is this young: TrackingConfig's
# LOCATION_REQUEST_TIMEOUT_MS, so the app stops waiting when the router does.
PA_REFRESH_WINDOW=90
PA_BACKOFF_MAX=300
# A contact failure that lasts this long counts as an internet outage.
PA_OUTAGE_MIN=90
PA_MAX_CLIENTS=64
# The most connections the agent reads in one pass of the connection table (for the
# data wired devices use). A bigger table takes seconds to read on a small router;
# that pass is skipped, and the next one under the limit counts what it missed of
# the connections still open.
PA_CT_MAX=20000
# When a wired device joined, which no table on a router records, is when the agent
# first saw it live. One unseen this long has left, and joins again when it is back.
# A device already there when the agent first looks, more than PA_JOIN_BOOT after
# boot, joined at some unknown time before: it gets no time until it joins again.
PA_JOIN_GAP=600
PA_JOIN_BOOT=900
# Traffic history: 48 samples, at least 270 s apart, none older than 4 hours.
PA_HISTORY_MAX=48
PA_HISTORY_SPACING=270
# The least traffic a chart point may average over, so the first point after a start
# is not a ten-second blip.
PA_HISTORY_MIN_WINDOW=60
PA_HISTORY_AGE=14400
# Firebase ID tokens live an hour; refresh after 50 minutes.
PA_TOKEN_LIFE=3000
# 2025-01-01. A wall clock earlier than this has not been set by NTP yet, and
# nothing dated by it is written.
PA_MIN_EPOCH=1735689600

PA_TMP="$PA_ROOT/tmp/protection-agent"
PA_PIDFILE="$PA_TMP.pid"
PA_MARK="# protection-agent"

PA_AUTH_URL="${PA_AUTH_URL:-https://identitytoolkit.googleapis.com/v1/accounts:signUp}"
PA_TOKEN_URL="${PA_TOKEN_URL:-https://securetoken.googleapis.com/v1/token}"
PA_FS_URL="${PA_FS_URL:-https://firestore.googleapis.com/v1}"
PA_IPINFO_URL="${PA_IPINFO_URL:-https://ipinfo.io/json}"
PA_GEO_URL="${PA_GEO_URL:-https://api.beacondb.net/v1/geolocate}"
# A router has no GPS. Its position rides the device's own location fields, from
# the best source it has:
#   1. where the owner pinned it (pinnedLatitude/pinnedLongitude on its document,
#      read on every contact): exact, and always wins;
#   2. Wi-Fi positioning: the networks around it, through beaconDB (free, no key,
#      the community successor to Mozilla's location service), tens of metres where
#      beaconDB knows the neighbourhood;
#   3. the city its public IP places it in, drawn as an area this wide rather than
#      as a false point. Mirrors TrackingConfig.ROUTER_IP_AREA_RADIUS_M.
PA_IP_AREA_RADIUS_M="${PA_IP_AREA_RADIUS_M:-25000}"
# A pin set without an accuracy (a point dropped on the map, pasted coordinates).
PA_PIN_ACCURACY_M=10
# A router does not move, so a Wi-Fi fix is kept six hours (or until the WAN address
# changes); a failed attempt is not retried for an hour, so a quiet neighbourhood
# costs one scan and one call an hour at most. The scan answers in a few seconds; at
# most this many of the strongest networks are sent. An answer vaguer than
# PA_GEO_MAX_ACC is not a Wi-Fi fix (a lookup service can fall back to placing the
# caller by IP) and is not used.
PA_GEO_MAX_AGE=21600
PA_GEO_RETRY=3600
PA_GEO_MAX_APS=20
PA_GEO_MAX_ACC=1000
PA_SCAN_WAIT="${PA_SCAN_WAIT:-4}"
# Self-update: the agent on main of the public releases repo, the very file the
# install line downloads. Fixed here, never read from the device document: the
# owner's Update is a bare timestamp, so the most it can do is make the router
# fetch this file.
PA_UPDATE_URL="${PA_UPDATE_URL:-https://raw.githubusercontent.com/protection-dev/protection-releases/main/router/protection-agent.sh}"
# An owner's Update is answered while it is this young:
# TrackingConfig.ROUTER_AGENT_UPDATE_TIMEOUT_MS, when the app stops waiting.
PA_UPDATE_WINDOW=600
# A new agent is on trial until its first report. Started this many times without
# getting there, or not there this long after starting, it gives way to the agent
# it replaced.
PA_TRIAL_STARTS=3
PA_TRIAL_DEADLINE=1800

# -- Small helpers -----------------------------------------------------------------

# Looks a program up on PATH by hand: some routers' BusyBox is built without the
# `command` builtin (Asuswrt-Merlin on an RT-N18U), where `command -v` always fails.
pa_which() {
  pa_w_ifs=$IFS
  IFS=:
  for pa_w_dir in $PATH; do
    if [ -n "$pa_w_dir" ] && [ -f "$pa_w_dir/$1" ] && [ -x "$pa_w_dir/$1" ]; then
      IFS=$pa_w_ifs
      printf '%s\n' "$pa_w_dir/$1"
      return 0
    fi
  done
  IFS=$pa_w_ifs
  return 1
}

pa_have() { pa_which "$1" >/dev/null; }

pa_log() {
  if pa_have logger; then
    logger -t protection-agent "$*"
  fi
  [ "${PA_VERBOSE:-0}" = 1 ] && printf '%s\n' "$*" >&2
  return 0
}

pa_say() { printf '%s\n' "$*"; }
pa_die() { printf 'protection-agent: %s\n' "$*" >&2; exit 1; }

# pa_read VAR FILE: first line of FILE into VAR (empty when unreadable). No fork.
pa_read() {
  eval "$1=''"
  [ -r "$2" ] || return 1
  IFS= read -r "$1" < "$2"
  return 0
}

# pa_isnum VALUE: a non-negative integer.
# pa_ms VAR SECONDS: the same in milliseconds, written out rather than multiplied,
# since epoch milliseconds overflow a 32-bit shell (BusyBox on an RT-N18U).
pa_ms() {
  case $2 in
    0) eval "$1=0" ;;
    *) eval "$1=\${2}000" ;;
  esac
}

pa_isnum() {
  case $1 in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# Monotonic seconds since boot, into PA_NOW. Immune to NTP stepping the clock,
# which matters: a router's wall clock is often wrong for minutes after boot.
pa_clock() {
  pa_read _pa_up "$PA_ROOT/proc/uptime"
  PA_NOW=${_pa_up%%[. ]*}
  pa_isnum "$PA_NOW" || PA_NOW=0
}

# -- Platform --------------------------------------------------------------------

pa_detect_platform() {
  if [ -f "$PA_ROOT/etc/openwrt_release" ]; then
    PA_PLATFORM=openwrt
  elif pa_have nvram && [ -d "$PA_ROOT/jffs" ]; then
    PA_PLATFORM=merlin
  else
    PA_PLATFORM=unknown
  fi
  case $PA_PLATFORM in
    merlin)
      PA_HOME="$PA_ROOT/jffs/addons/protection"
      PA_BIN="$PA_HOME/protection-agent.sh"
      PA_CONF="${PA_CONF:-$PA_HOME/agent.conf}"
      ;;
    *)
      PA_HOME="$PA_ROOT/usr/bin"
      PA_BIN="$PA_HOME/protection-agent"
      PA_CONF="${PA_CONF:-$PA_ROOT/etc/protection-agent.conf}"
      ;;
  esac
}

# OpenWrt's own helpers resolve the WAN interface the way netifd sees it. Sourced
# once; the functions use a cached `ubus` dump that pa_wan flushes per report.
pa_init_platform() {
  PA_NETSH=0
  if [ "$PA_PLATFORM" = openwrt ] && [ -r "$PA_ROOT/lib/functions/network.sh" ]; then
    # shellcheck disable=SC1091
    . "$PA_ROOT/lib/functions/network.sh" && PA_NETSH=1
  fi
}

# Merlin: one `nvram show` per report instead of a fork per variable. Only the
# variables the agent reads are kept, as PA_NV_<name> with dots made underscores.
pa_nvram_snapshot() {
  [ "$PA_PLATFORM" = merlin ] || return 0
  nvram show 2>/dev/null | awk -F= '
    /^(wan_primary|wan[01]_(ifname|proto|ipaddr)|wl[0-3]_(ifname|nband|ssid|radio)|wl[0-3]\.[1-3]_bss_enabled|lan_ifname|productid|odmpid|buildno|extendno|firmver|lan_hwaddr|jffs2_scripts|custom_clientlist|ctf_disable)=/ {
      key = $1; gsub(/\./, "_", key)
      print key "=" substr($0, length($1) + 2)
    }' > "$PA_TMP.nv" 2>/dev/null
  # Assigned, never evaluated: an SSID full of quotes and dollar signs is still
  # just text. The key was matched against a fixed list above.
  while IFS= read -r _line; do
    _k=${_line%%=*}
    case $_k in
      '' | *[!A-Za-z0-9_]*) continue ;;
    esac
    _v=${_line#*=}
    eval "PA_NV_$_k=\$_v"
  done < "$PA_TMP.nv"
  rm -f "$PA_TMP.nv"
}

# pa_nv NAME: a snapshotted nvram value into PA_V.
pa_nv() {
  eval "PA_V=\${PA_NV_$1:-}"
}

# -- Identity ---------------------------------------------------------------------

pa_identity() {
  PA_MF=''
  PA_MODEL=''
  PA_FW=''
  case $PA_PLATFORM in
    merlin)
      PA_MF=ASUS
      pa_nv odmpid
      PA_MODEL=$PA_V
      if [ -z "$PA_MODEL" ]; then
        pa_nv productid
        PA_MODEL=$PA_V
      fi
      # RT-AX86U_PRO reads better as RT-AX86U PRO.
      PA_MODEL=$(printf '%s' "$PA_MODEL" | tr '_' ' ')
      pa_nv firmver
      _fv=$(printf '%s' "$PA_V" | tr -d '.')
      pa_nv buildno
      _bn=$PA_V
      pa_nv extendno
      _ex=$PA_V
      # As the router's own web UI writes it (state.js): no suffix for an extendno
      # of 0, so 3006.102.9 rather than 3006.102.9_0.
      [ "$_ex" = 0 ] && _ex=''
      _flavour=Asuswrt
      [ -x "$PA_ROOT/usr/sbin/helper.sh" ] && _flavour=Asuswrt-Merlin
      PA_FW="$_flavour $_fv.$_bn${_ex:+_$_ex}"
      ;;
    openwrt)
      _id=OpenWrt
      _rel=''
      while IFS='=' read -r _k _v; do
        _v=${_v#\'}
        _v=${_v%\'}
        _v=${_v#\"}
        _v=${_v%\"}
        case $_k in
          DISTRIB_ID) _id=$_v ;;
          DISTRIB_RELEASE) _rel=$_v ;;
        esac
      done < "$PA_ROOT/etc/openwrt_release"
      PA_FW="$_id${_rel:+ $_rel}"
      pa_read _m "$PA_ROOT/tmp/sysinfo/model"
      # "GL.iNet GL-MT6000": the first word is the maker, the rest the model.
      case $_m in
        *' '*)
          PA_MF=${_m%% *}
          PA_MODEL=${_m#* }
          ;;
        *) PA_MODEL=$_m ;;
      esac
      ;;
  esac
  [ -n "$PA_MODEL" ] || PA_MODEL=Router
}

# A stable id that survives a reinstall: a hash of the LAN MAC, so the dashboard
# can recognise a re-enrolling router without holding its MAC in the clear.
pa_hardware_id() {
  pa_lan_device
  pa_read _mac "$PA_ROOT/sys/class/net/$PA_LAN_DEV/address"
  if [ -z "$_mac" ]; then
    pa_nv lan_hwaddr
    _mac=$PA_V
  fi
  _mac=$(printf '%s' "$_mac" | tr 'A-F' 'a-f')
  if pa_have sha256sum; then
    PA_HW=$(printf 'protection-router:%s' "$_mac" | sha256sum)
  elif pa_have md5sum; then
    PA_HW=$(printf 'protection-router:%s' "$_mac" | md5sum)
  else
    PA_HW=$(printf '%s' "$_mac" | tr -d ':')
  fi
  PA_HW=${PA_HW%% *}
  case $PA_HW in
    *[!0-9a-f]* | '') PA_HW='' ;;
  esac
}

# -- Network devices ----------------------------------------------------------------

pa_lan_device() {
  PA_LAN_DEV=''
  case $PA_PLATFORM in
    merlin)
      pa_nv lan_ifname
      PA_LAN_DEV=$PA_V
      ;;
    openwrt)
      [ "$PA_NETSH" = 1 ] && network_get_device PA_LAN_DEV lan 2>/dev/null
      ;;
  esac
  if [ -z "$PA_LAN_DEV" ]; then
    for _d in br-lan br0 eth0; do
      if [ -d "$PA_ROOT/sys/class/net/$_d" ]; then
        PA_LAN_DEV=$_d
        break
      fi
    done
  fi
}

# Interfaces that can hold a default route without being the WAN: VPN clients,
# Tailscale, WireGuard, ZeroTier, container bridges.
pa_is_virtual() {
  case $1 in
    tailscale* | tun* | tap* | wg* | zt* | nordlynx* | docker* | veth* | lo | ipsec* | gre* | vti* | ifb* | wgc* | wgs*) return 0 ;;
  esac
  return 1
}

# The default route's interface in the main table, skipping virtual ones. Policy
# routing (Tailscale's table 52, Merlin's VPN Director) never shows up here, and a
# VPN that splits 0/1 + 128/1 never matches a 0/0 route, so this lands on the WAN.
pa_wan_from_routes() {
  _best=''
  _bestm=''
  [ -r "$PA_ROOT/proc/net/route" ] || return 1
  while read -r _if _dst _gw _fl _rc _use _met _mask _rest; do
    [ "$_dst" = 00000000 ] && [ "$_mask" = 00000000 ] || continue
    pa_is_virtual "$_if" && continue
    pa_isnum "$_met" || _met=0
    if [ -z "$_best" ] || [ "$_met" -lt "$_bestm" ]; then
      _best=$_if
      _bestm=$_met
    fi
  done < "$PA_ROOT/proc/net/route"
  [ -n "$_best" ] || return 1
  PA_WAN_DEV=$_best
  return 0
}

pa_proto_label() {
  case $1 in
    dhcp | dhcpv6) PA_WAN_TYPE=DHCP ;;
    pppoe) PA_WAN_TYPE=PPPoE ;;
    static) PA_WAN_TYPE=Static ;;
    pptp) PA_WAN_TYPE=PPTP ;;
    l2tp) PA_WAN_TYPE=L2TP ;;
    qmi | mbim | ncm | modemmanager | 3g | wwan | lte | usb | usbmodem) PA_WAN_TYPE=Mobile ;;
    '') PA_WAN_TYPE='' ;;
    *) PA_WAN_TYPE=$1 ;;
  esac
}

# Sets PA_WAN_DEV (the device whose byte counters are read), PA_WAN_TYPE,
# PA_WAN_IP (the router's own WAN address) and PA_WAN_UP (seconds, when known).
pa_wan() {
  PA_WAN_DEV=''
  PA_WAN_TYPE=''
  PA_WAN_IP=''
  PA_WAN_UP=''
  case $PA_PLATFORM in
    merlin)
      pa_nv wan_primary
      _u=$PA_V
      case $_u in [01]) ;; *) _u=0 ;; esac
      pa_nv "wan${_u}_proto"
      pa_proto_label "$PA_V"
      # The physical port, not ppp0: its counters include hardware-accelerated
      # traffic that never passes through the PPP device.
      pa_nv "wan${_u}_ifname"
      PA_WAN_DEV=$PA_V
      pa_nv "wan${_u}_ipaddr"
      PA_WAN_IP=$PA_V
      ;;
    openwrt)
      if [ "$PA_NETSH" = 1 ]; then
        network_flush_cache 2>/dev/null
        _iface=''
        # Prefer the interface called wan. A WireGuard or OpenVPN interface with
        # a 0/0 route would otherwise win network_find_wan.
        if network_is_up wan 2>/dev/null; then
          _iface=wan
        else
          network_find_wan _iface 2>/dev/null
        fi
        _proto=''
        [ -n "$_iface" ] && network_get_protocol _proto "$_iface" 2>/dev/null
        case $_proto in
          wireguard | openvpn | vpnc | zerotier | tailscale | gre* | vti*)
            _iface=wan
            network_get_protocol _proto wan 2>/dev/null
            ;;
        esac
        if [ -n "$_iface" ]; then
          pa_proto_label "$_proto"
          network_get_physdev PA_WAN_DEV "$_iface" 2>/dev/null
          [ -n "$PA_WAN_DEV" ] || network_get_device PA_WAN_DEV "$_iface" 2>/dev/null
          network_get_ipaddr PA_WAN_IP "$_iface" 2>/dev/null
          network_get_uptime PA_WAN_UP "$_iface" 2>/dev/null
        fi
      fi
      ;;
  esac
  pa_isnum "$PA_WAN_UP" || PA_WAN_UP=''
  if [ -z "$PA_WAN_DEV" ] || [ ! -d "$PA_ROOT/sys/class/net/$PA_WAN_DEV/statistics" ] || pa_is_virtual "$PA_WAN_DEV"; then
    pa_wan_from_routes || PA_WAN_DEV=''
  fi
}

# -- Measurements -------------------------------------------------------------------

# WAN byte counters, accumulated every contact so a 32-bit counter that wraps
# between two five-minute reports (it can, at 100 Mbps) is caught and corrected.
# Two windows over the same bytes: PA_ACC_* since the last report (the headline
# rate), PA_HACC_* since the last chart point (that point's average).
#
# The sums are awk's, not the shell's: some BusyBox shells do 32-bit arithmetic
# (Merlin on an RT-N18U), which a few minutes of traffic overflows. awk's doubles
# stay exact to 2^53 bytes. A negative delta means a 32-bit counter wrapped (add
# 2^32) or the interface was reset (count nothing rather than a bogus terabyte).
PA_AWK_ACCUMULATE='
function delta(now, prev,   x) {
  x = now - prev
  if (x < 0) {
    if (prev < 4294967296) x += 4294967296
    if (x < 0 || prev >= 4294967296) x = 0
  }
  return x
}
BEGIN {
  r = delta(rx, prx)
  t = delta(tx, ptx)
  printf "%.0f %.0f %.0f %.0f\n", arx + r, atx + t, hrx + r, htx + t
}
'

pa_accumulate() {
  [ -n "$PA_WAN_DEV" ] || return 0
  _stat="$PA_ROOT/sys/class/net/$PA_WAN_DEV/statistics"
  pa_read _rx "$_stat/rx_bytes"
  pa_read _tx "$_stat/tx_bytes"
  if ! pa_isnum "$_rx" || ! pa_isnum "$_tx"; then
    PA_PREV_RX=''
    return 0
  fi
  if [ -n "${PA_PREV_RX:-}" ] && [ "${PA_PREV_DEV:-}" = "$PA_WAN_DEV" ]; then
    # shellcheck disable=SC2046
    set -- $(awk -v rx="$_rx" -v tx="$_tx" -v prx="$PA_PREV_RX" -v ptx="$PA_PREV_TX" \
      -v arx="${PA_ACC_RX:-0}" -v atx="${PA_ACC_TX:-0}" \
      -v hrx="${PA_HACC_RX:-0}" -v htx="${PA_HACC_TX:-0}" "$PA_AWK_ACCUMULATE")
    if pa_isnum "${4:-}"; then
      PA_ACC_RX=$1
      PA_ACC_TX=$2
      PA_HACC_RX=$3
      PA_HACC_TX=$4
    fi
  else
    # A new device (WAN failover) or the first sample: start both windows here.
    PA_ACC_RX=0
    PA_ACC_TX=0
    PA_ACC_FROM=$PA_NOW
    PA_HACC_RX=0
    PA_HACC_TX=0
    PA_HACC_FROM=$PA_NOW
  fi
  PA_PREV_RX=$_rx
  PA_PREV_TX=$_tx
  PA_PREV_DEV=$PA_WAN_DEV
}

# The average rate since the last report, then a fresh window. Empty until a
# window of at least five seconds exists.
#
# And the average since the last chart point, for the next one. Separate because the
# report pace changes: while the owner watches, reports come every ten seconds, and a
# point taken from one of those would draw a ten-second burst as four and a half
# minutes of traffic. Averaged over the whole gap, a point means the same thing
# whether anyone was watching or not.
pa_rates() {
  PA_RX_BPS=''
  PA_TX_BPS=''
  PA_HRX_BPS=''
  PA_HTX_BPS=''
  if [ -n "${PA_HACC_FROM:-}" ]; then
    _span=$((PA_NOW - PA_HACC_FROM))
    if [ "$_span" -ge "$PA_HISTORY_MIN_WINDOW" ]; then
      # shellcheck disable=SC2046
      set -- $(pa_bps "$_span" "$PA_HACC_RX" "$PA_HACC_TX")
      PA_HRX_BPS=${1:-}
      PA_HTX_BPS=${2:-}
    fi
  fi
  [ -n "${PA_ACC_FROM:-}" ] || return 0
  _span=$((PA_NOW - PA_ACC_FROM))
  [ "$_span" -ge 5 ] || return 0
  # shellcheck disable=SC2046
  set -- $(pa_bps "$_span" "$PA_ACC_RX" "$PA_ACC_TX")
  PA_RX_BPS=${1:-}
  PA_TX_BPS=${2:-}
}

# pa_bps SECONDS RXBYTES TXBYTES: both as whole bits per second, in awk because
# bytes times 8 overflows a 32-bit shell past 268 MB.
pa_bps() {
  awk -v s="$1" -v r="$2" -v t="$3" 'BEGIN { printf "%.0f %.0f\n", int(r * 8 / s), int(t * 8 / s) }'
}

pa_rates_reset() {
  PA_ACC_RX=0
  PA_ACC_TX=0
  PA_ACC_FROM=$PA_NOW
}

# CPU busy percent since the previous report, from /proc/stat's first line: user
# through steal make the total, idle and iowait the idle. Summed in awk, as the
# jiffy totals pass 2^31 after a few months up, where a 32-bit shell wraps.
PA_AWK_CPU='
NR == 1 {
  for (i = 2; i <= 9 && i <= NF; i++) if ($i ~ /^[0-9]+$/) total += $i
  if ($5 ~ /^[0-9]+$/) idle += $5
  if ($6 ~ /^[0-9]+$/) idle += $6
  busy = ""
  if (pt != "") {
    dt = total - pt
    di = idle - pi
    if (dt > 0 && di >= 0) {
      busy = int((dt - di) * 100 / dt)
      if (busy < 0) busy = 0
      if (busy > 100) busy = 100
    }
  }
  printf "%.0f %.0f %s\n", total, idle, busy
  exit
}
'

pa_cpu() {
  PA_CPU=''
  [ -r "$PA_ROOT/proc/stat" ] || return 0
  # shellcheck disable=SC2046
  set -- $(awk -v pt="${PA_CPU_TOTAL:-}" -v pi="${PA_CPU_IDLE:-}" "$PA_AWK_CPU" "$PA_ROOT/proc/stat")
  PA_CPU_TOTAL=${1:-}
  PA_CPU_IDLE=${2:-}
  PA_CPU=${3:-}
}

# Memory in bytes. "Used" excludes page cache (MemTotal - MemAvailable), and falls
# back to Free + Buffers + Cached on the 2.6 kernels older Asus models still run.
pa_memory() {
  PA_MEM_TOTAL=''
  PA_MEM_USED=''
  [ -r "$PA_ROOT/proc/meminfo" ] || return 0
  _tot=''
  _avail=''
  _free=0
  _buf=0
  _cached=0
  _srec=0
  while read -r _k _v _unit; do
    pa_isnum "$_v" || continue
    case $_k in
      MemTotal:) _tot=$_v ;;
      MemAvailable:) _avail=$_v ;;
      MemFree:) _free=$_v ;;
      Buffers:) _buf=$_v ;;
      Cached:) _cached=$_v ;;
      SReclaimable:) _srec=$_v ;;
    esac
  done < "$PA_ROOT/proc/meminfo"
  pa_isnum "$_tot" || return 0
  [ -n "$_avail" ] || _avail=$((_free + _buf + _cached + _srec))
  [ "$_avail" -gt "$_tot" ] && _avail=$_tot
  # Bytes in awk: 2 GB of RAM overflows a 32-bit shell's arithmetic.
  # shellcheck disable=SC2046
  set -- $(awk -v t="$_tot" -v a="$_avail" 'BEGIN { printf "%.0f %.0f\n", t * 1024, (t - a) * 1024 }')
  PA_MEM_TOTAL=${1:-}
  PA_MEM_USED=${2:-}
}

# The hottest sensor the firmware exposes, in whole degrees C.
pa_temperature() {
  PA_TEMP=''
  for _f in "$PA_ROOT"/sys/class/thermal/thermal_zone*/temp "$PA_ROOT"/sys/class/hwmon/hwmon*/temp*_input; do
    [ -r "$_f" ] || continue
    pa_read _t "$_f"
    pa_isnum "$_t" || continue
    # Millidegrees on every current kernel; a few drivers report whole degrees.
    [ "$_t" -ge 1000 ] && _t=$((_t / 1000))
    [ "$_t" -gt 0 ] && [ "$_t" -lt 150 ] || continue
    if [ -z "$PA_TEMP" ] || [ "$_t" -gt "$PA_TEMP" ]; then
      PA_TEMP=$_t
    fi
  done
  # Older Broadcom Asus models: "CPU temperature : 58°C".
  if [ -z "$PA_TEMP" ] && [ -r "$PA_ROOT/proc/dmu/temperature" ]; then
    pa_read _t "$PA_ROOT/proc/dmu/temperature"
    _t=${_t#*:}
    _t=${_t#"${_t%%[0-9]*}"}
    _t=${_t%%[!0-9]*}
    pa_isnum "$_t" && [ "$_t" -gt 0 ] && [ "$_t" -lt 150 ] && PA_TEMP=$_t
  fi
  PA_FAN=''
  for _f in "$PA_ROOT"/sys/class/hwmon/hwmon*/fan1_input; do
    [ -r "$_f" ] || continue
    pa_read _t "$_f"
    if pa_isnum "$_t"; then
      PA_FAN=$_t
      break
    fi
  done
}

pa_uptime() {
  pa_read _pa_up "$PA_ROOT/proc/uptime"
  PA_UP=${_pa_up%%[. ]*}
  pa_isnum "$PA_UP" || PA_UP=''
}

# -- Wireless -------------------------------------------------------------------------
# Both platforms write one stream of raw tool output to $PA_TMP.wifi, marked up with
# @RADIO / @IF / @STA / @SURVEY lines, and the report's awk pass parses all of it.

pa_wifi_openwrt() {
  pa_have iw || return 0
  # AP interfaces, their SSID, channel and width, as @RADIO lines.
  iw dev 2>/dev/null | awk '
    function out() {
      if (name != "" && type == "AP") {
        band = (freq + 0 < 3000) ? "2" : ((freq + 0 < 5925) ? "5" : "6")
        printf "@RADIO\t%s\t%s\t%s\t%s\t%s\n", name, band, ch, width, ssid
      }
    }
    /^[ \t]*Interface / { out(); name = $2; type = ""; ssid = ""; ch = ""; freq = ""; width = ""; next }
    /^[ \t]*ssid / { s = $0; sub(/^[ \t]*ssid /, "", s); ssid = s; next }
    /^[ \t]*type / { type = $2; next }
    /^[ \t]*channel / {
      ch = $2; f = $3; gsub(/[^0-9]/, "", f); freq = f
      w = $0
      if (sub(/.*width: /, "", w)) { sub(/[^0-9].*/, "", w); width = w }
      next
    }
    END { out() }
  ' > "$PA_TMP.radios" 2>/dev/null
  cat "$PA_TMP.radios"
  while IFS='	' read -r _tag _if _band _rest; do
    [ "$_tag" = @RADIO ] || continue
    printf '@IF\t%s\t%s\t%s\n' "$_if" "$_band" "$_if"
    iw dev "$_if" station dump 2>/dev/null
    printf '@SURVEY\t%s\n' "$_if"
    iw dev "$_if" survey dump 2>/dev/null
  done < "$PA_TMP.radios"
  rm -f "$PA_TMP.radios"
}

# Broadcom `wl` chanspec: "36/80 (0xe02a)", "6 (0x1006)", "6l", "6g37/160".
pa_chanspec() {
  _cs=${1%% *}
  _cs=${_cs#[256]g}
  PA_CH=${_cs%%[!0-9]*}
  case $_cs in
    */320) PA_WIDTH=320 ;;
    */160) PA_WIDTH=160 ;;
    */80) PA_WIDTH=80 ;;
    */40 | *l | *u) PA_WIDTH=40 ;;
    *) PA_WIDTH=20 ;;
  esac
}

pa_wifi_merlin() {
  pa_have wl || return 0
  for _u in 0 1 2 3; do
    pa_nv "wl${_u}_ifname"
    _if=$PA_V
    [ -n "$_if" ] || continue
    pa_nv "wl${_u}_radio"
    [ "$PA_V" = 0 ] && continue
    pa_nv "wl${_u}_nband"
    case $PA_V in
      2) _band=2 ;;
      1) _band=5 ;;
      4) _band=6 ;;
      *) continue ;;
    esac
    pa_nv "wl${_u}_ssid"
    _ssid=$PA_V
    pa_chanspec "$(wl -i "$_if" chanspec 2>/dev/null)"
    printf '@RADIO\t%s\t%s\t%s\t%s\t%s\n' "$_if" "$_band" "$PA_CH" "$PA_WIDTH" "$_ssid"
    # How busy the channel is, from the driver's own channel-utilisation sample.
    printf '@CHANIM\t%s\n' "$_if"
    wl -i "$_if" chanim_stats 2>/dev/null
    # The radio itself, then its guest networks, all counted against the radio.
    for _vif in "$_if" "wl$_u.1" "wl$_u.2" "wl$_u.3"; do
      if [ "$_vif" != "$_if" ]; then
        pa_nv "wl${_u}_${_vif##*.}_bss_enabled"
        [ "$PA_V" = 1 ] || continue
      fi
      printf '@IF\t%s\t%s\t%s\n' "$_vif" "$_band" "$_if"
      wl -i "$_vif" assoclist 2>/dev/null > "$PA_TMP.assoc"
      while read -r _a _mac _rest; do
        [ "$_a" = assoclist ] || continue
        printf '@STA\t%s\n' "$_mac"
        wl -i "$_vif" sta_info "$_mac" 2>/dev/null
      done < "$PA_TMP.assoc"
    done
  done
  rm -f "$PA_TMP.assoc"
}

pa_wifi() {
  : > "$PA_TMP.wifi"
  case $PA_PLATFORM in
    openwrt) pa_wifi_openwrt > "$PA_TMP.wifi" ;;
    merlin) pa_wifi_merlin > "$PA_TMP.wifi" ;;
  esac
}

pa_leases_file() {
  PA_LEASES=/dev/null
  for _f in "$PA_ROOT/tmp/dhcp.leases" "$PA_ROOT/var/lib/misc/dnsmasq.leases" "$PA_ROOT/tmp/var/lib/misc/dnsmasq.leases"; do
    if [ -r "$_f" ]; then
      PA_LEASES=$_f
      return 0
    fi
  done
}

# Names the owner gave devices in the router's own UI, as "mac<TAB>name" lines in
# $PA_TMP.names. They win over a DHCP hostname ("garage" over "ESP_3B5F16"), and
# they are often the only name a wired or static-IP device has: such a device
# never asks DHCP for a lease, so it never appears in the lease file. OpenWrt keeps
# them as static leases (dhcp host sections), Merlin in its client list.
pa_static_names() {
  : > "$PA_TMP.names"
  case $PA_PLATFORM in
    openwrt)
      pa_have uci || return 0
      # dhcp.<section>.name='garage' and dhcp.<section>.mac='BC:07:...' (or a
      # space-separated list of MACs for one name).
      uci -q show dhcp 2>/dev/null | awk -F= '
        /^dhcp\.[^.]+\.(name|mac)=/ {
          split($1, k, "."); v = substr($0, length($1) + 2); gsub(/\047/, "", v)
          if (k[3] == "name") name[k[2]] = v; else mac[k[2]] = v
        }
        END {
          for (s in mac) if (s in name) {
            c = split(mac[s], m, " ")
            for (i = 1; i <= c; i++) printf "%s\t%s\n", tolower(m[i]), name[s]
          }
        }' > "$PA_TMP.names"
      ;;
    merlin)
      # <Living room TV>AA:BB:CC:DD:EE:FF>0>0>><Laptop>11:22:...
      pa_nv custom_clientlist
      [ -n "$PA_V" ] || return 0
      printf '%s' "$PA_V" | awk -v RS='<' -F'>' 'NF >= 2 && $2 != "" { printf "%s\t%s\n", tolower($2), $1 }' > "$PA_TMP.names"
      ;;
  esac
}

# Which addresses are devices on the LAN, for both awk programs that read the ARP
# table. `lan` and `wan` are the LAN bridge and the WAN device: an entry on the WAN
# (the ISP's gateway) or on a container bridge is not a device of the home's.
PA_AWK_HOST='
function macok(m) { return m ~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])$/ && m != "00:00:00:00:00:00" }
function lanok(dev) {
  if (dev == "" || index(" " wan " ", " " dev " ") > 0) return 0
  if (dev ~ /^br-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$/) return 0
  if (lan != "" && dev == lan) return 1
  return dev ~ /^br/
}
'

# -- Wired devices -------------------------------------------------------------------
# A wired device has no station table to read its bytes from, so its data comes from
# the connection table instead (conntrack): for every connection through the router,
# the kernel keeps the bytes each way. A connection leaves the table soon after it
# ends (two minutes after a TCP close, half a minute to three for UDP), so it is read at
# every contact, not every report: once a minute, nearly every connection is seen
# with its final count. What each connection grew by since the previous read goes to
# the device at its LAN end, found by its IPv4 address (ARP) or IPv6 address (the
# neighbour table), and adds up in $PA_TMP.ctacc until the next report puts it in
# that device's hourly bucket. What a device sends straight to another at home is
# switched, never routed, so it is not in the table and not counted.
#
# $PA_TMP.ct holds the previous read: "@ SECONDS", then one line per connection of a
# device ("KEY MAC DIRECTION ORIGBYTES REPLYBYTES"). KEY is the protocol and the
# original direction (addresses, ports), the same for a connection's whole life. A
# connection the previous read did not have opened since then, and all of it counts;
# on the first read of the boot, nothing does. A count that went down belongs to a
# new connection that reused the same addresses and ports. DIRECTION o: the device
# opened it, so the original direction is its upload; r: it was opened to the device
# (a port forward), so it is its download. Prints the connections with byte counts,
# those without, and those of devices.
#
# The same read says which devices are live: those with a connection in the table, or
# a neighbour entry the router confirmed lately (REACHABLE, DELAY, PROBE; STALE only
# means it was there once). $PA_TMP.seen keeps when each live device joined: "@
# SECONDS" (this read), then "MAC JOINED LASTSEEN", JOINED "-" when it was already there
# before the agent could tell. A device gone longer than `gap` is dropped, so it joins
# anew when it is back. A read more than `gap` after the previous one (the agent was
# stopped or dormant) cannot tell who left: devices it knew keep their time, and new
# ones get none.
PA_AWK_CT='
function hex4(g) { while (length(g) < 4) g = "0" g; return g }
# An IPv6 address as the connection table prints it: eight groups of four digits.
function v6full(a,    p, l, r, nl, nr, lp, rp, out, sep, i) {
  a = tolower(a); sub(/%.*/, "", a)
  if (a !~ /^[0-9a-f:]+$/) return ""
  out = ""; sep = ""
  p = index(a, "::")
  if (p == 0) {
    if (split(a, lp, ":") != 8) return ""
    for (i = 1; i <= 8; i++) { out = out sep hex4(lp[i]); sep = ":" }
    return out
  }
  l = substr(a, 1, p - 1); r = substr(a, p + 2)
  if (index(r, "::") > 0) return ""
  nl = (l == "") ? 0 : split(l, lp, ":")
  nr = (r == "") ? 0 : split(r, rp, ":")
  if (nl + nr > 7) return ""
  for (i = 1; i <= nl; i++) { out = out sep hex4(lp[i]); sep = ":" }
  for (i = 1; i <= 8 - nl - nr; i++) { out = out sep "0000"; sep = ":" }
  for (i = 1; i <= nr; i++) { out = out sep hex4(rp[i]); sep = ":" }
  return out
}
BEGIN { printf("@ %s\n", now) > ctout }
FILENAME == arp {
  if (FNR == 1) next
  m = tolower($4)
  if (($3 == "0x2" || $3 == "0x6") && macok(m) && lanok($6)) host[$1] = m
  next
}
# `ip neigh`: "2a01:e0a::1f dev br-lan lladdr aa:bb:cc:dd:ee:ff STALE", and the same
# for IPv4 addresses.
FILENAME == neigh {
  ndev = ""; m = ""
  for (i = 2; i < NF; i++) {
    if ($i == "dev") ndev = $(i + 1)
    else if ($i == "lladdr") m = tolower($(i + 1))
  }
  if (!macok(m) || !lanok(ndev)) next
  if (index($1, ":") > 0) { full = v6full($1); if (full != "") host[full] = m }
  else host[$1] = m
  if ($NF == "REACHABLE" || $NF == "DELAY" || $NF == "PROBE") live[m] = 1
  next
}
FILENAME == seen {
  if ($1 == "@") seenat = $2
  else if (macok($1) && NF == 3 && $3 ~ /^[0-9]+$/) { sf[$1] = $2; sl[$1] = $3 }
  next
}
FILENAME == prevct {
  if ($1 == "@") prevat = $2
  else if (NF == 5) { pm[$1] = $2; pd[$1] = $3; po[$1] = $4; pb[$1] = $5 }
  next
}
FILENAME == acc {
  if ($1 == "@") from = $2
  else if (macok($1) && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/) { adn[$1] += $2; aup[$1] += $3 }
  next
}
# "ipv4 2 tcp 6 117 ESTABLISHED src=A dst=B sport=P dport=Q packets=N bytes=N
# src=B dst=A sport=Q dport=P packets=N bytes=N [ASSURED] mark=0 use=1", or the
# same without the first two fields from an old kernel ip_conntrack. No bytes=
# when the kernel keeps no counts.
FILENAME == ct {
  proto = ($1 ~ /^ipv[46]$/) ? $3 : $1
  key = proto; ns = 0; os = ""; od = ""; rs = ""; ob = ""; rb = ""
  for (i = 2; i <= NF; i++) {
    e = index($i, "=")
    if (e == 0) continue
    k = substr($i, 1, e - 1); v = substr($i, e + 1)
    if (k == "src") {
      ns++
      if (ns == 1) os = v
      else if (ns == 2) rs = v
      else break
    } else if (k == "bytes") {
      if (ns == 1) { ob = v; continue }
      rb = v
      break
    } else if (ns == 1 && k == "dst") od = v
    if (ns == 1 && k != "packets") key = key "," v
  }
  counts = (ob ~ /^[0-9]+$/ && rb ~ /^[0-9]+$/)
  if (counts) ncount++; else nbare++
  if (index(os, "::") > 0) os = v6full(os)
  if (index(od, "::") > 0) od = v6full(od)
  if (index(rs, "::") > 0) rs = v6full(rs)
  if (key in pm) { m = pm[key]; d = pd[key] }
  else if (os in host) { m = host[os]; d = "o" }
  else if (rs in host) { m = host[rs]; d = "r" }
  else if (od in host) { m = host[od]; d = "r" }
  else next
  # A connection in the table, counted or not, says the device is there.
  live[m] = 1
  if (!counts) next
  if (key in pm) {
    xo = ob - po[key]; xr = rb - pb[key]
    if (xo < 0 || xr < 0) { xo = ob + 0; xr = rb + 0 }
  } else if (fresh == "1") { xo = 0; xr = 0 }
  else { xo = ob + 0; xr = rb + 0 }
  nlan++
  printf("%s %s %s %s %s\n", key, m, d, ob, rb) > ctout
  if (d == "o") { aup[m] += xo; adn[m] += xr } else { adn[m] += xo; aup[m] += xr }
  next
}
END {
  close(ctout)
  # Counting begins with the first report of the boot; until then this only keeps
  # the table, as the starting point. The window starts at the read before this one.
  if (counting == "1") {
    if (from == "") from = (prevat != "") ? prevat : now
    printf("@ %s\n", from) > accout
    for (m in adn) printf("%s %.0f %.0f\n", m, adn[m], aup[m]) > accout
    close(accout)
  }
  # When each live device joined. On the first look of the boot, a device already
  # there joined with the boot if the boot was recent, else at a time nobody knows.
  looked = (seenat != "" && now - seenat <= gap)
  printf("@ %s\n", now) > seenout
  for (m in live) {
    if ((m in sf) && (!looked || now - sl[m] <= gap)) j = sf[m]
    else if (seenat != "") j = looked ? now : "-"
    else j = (up + 0 <= bootwin + 0) ? now : "-"
    printf("%s %s %s\n", m, j, now) > seenout
  }
  # One not live this time is kept a while: a quiet minute is not leaving.
  for (m in sf) if (!(m in live) && now - sl[m] <= gap) printf("%s %s %s\n", m, sf[m], sl[m]) > seenout
  close(seenout)
  printf("%d %d %d\n", ncount, nbare, nlan)
}
'

# The connection table: nf_conntrack, or the ip_conntrack an old kernel still has.
pa_ct_file() {
  PA_CT_FILE=''
  for _f in "$PA_ROOT/proc/net/nf_conntrack" "$PA_ROOT/proc/net/ip_conntrack"; do
    if [ -r "$_f" ]; then
      PA_CT_FILE=$_f
      return 0
    fi
  done
  return 1
}

# The kernel counts bytes per connection only when told to. OpenWrt tells it at
# boot; other firmware may not, and without the counts no wired device has figures.
# The service turns them on: a runtime switch, in RAM, which a reboot turns off
# again until the service starts and turns it back on. Connections open before then
# carry no counts. Marked, so uninstall can put it back.
pa_ct_enable() {
  _acct="$PA_ROOT/proc/sys/net/netfilter/nf_conntrack_acct"
  pa_read _v "$_acct" || return 0
  [ "$_v" = 0 ] || return 0
  if printf '1\n' 2>/dev/null > "$_acct"; then
    : > "$PA_TMP.acct-on"
    pa_log "turned on connection byte counting, for the data wired devices use"
  fi
  return 0
}

# One read of the connection table. Sets PA_CT_STATE: ok (counted), busy (too big to
# read this time), off (the kernel keeps no byte counts) or none (no table), and
# PA_CT_FLOWS, the connections it had. PA_CT_FRESH tells the report this read is
# this contact's, so it does not read the table again.
pa_ct_sample() {
  PA_CT_FRESH=1
  PA_CT_STATE=none
  PA_CT_FLOWS=0
  pa_ct_file || return 0
  pa_read _ctn "$PA_ROOT/proc/sys/net/netfilter/nf_conntrack_count"
  if pa_isnum "$_ctn" && [ "$_ctn" -gt "$PA_CT_MAX" ]; then
    PA_CT_STATE=busy
    PA_CT_FLOWS=$_ctn
    return 0
  fi
  _n6=/dev/null
  if pa_have ip && ip neigh show > "$PA_TMP.n6" 2>/dev/null; then _n6="$PA_TMP.n6"; fi
  _seen="$PA_TMP.seen"
  [ -r "$_seen" ] || _seen=/dev/null
  _arp="$PA_ROOT/proc/net/arp"
  [ -r "$_arp" ] || _arp=/dev/null
  _prev="$PA_TMP.ct"
  _fresh=0
  if [ ! -r "$_prev" ]; then
    _prev=/dev/null
    _fresh=1
  fi
  _acc="$PA_TMP.ctacc"
  [ -r "$_acc" ] || _acc=/dev/null
  _counting=0
  [ -r "$PA_TMP.usage.since" ] && _counting=1
  rm -f "$PA_TMP.ct.new" "$PA_TMP.ctacc.new" "$PA_TMP.seen.new"
  # shellcheck disable=SC2046
  set -- $(awk -v arp="$_arp" -v neigh="$_n6" -v seen="$_seen" -v prevct="$_prev" -v acc="$_acc" -v ct="$PA_CT_FILE" \
    -v ctout="$PA_TMP.ct.new" -v accout="$PA_TMP.ctacc.new" -v seenout="$PA_TMP.seen.new" \
    -v lan="${PA_LAN_DEV:-}" -v wan="${PA_WAN_DEV:-}" -v now="$PA_WALL" -v up="${PA_NOW:-0}" \
    -v gap="$PA_JOIN_GAP" -v bootwin="$PA_JOIN_BOOT" -v fresh="$_fresh" -v counting="$_counting" \
    "$PA_AWK_HOST$PA_AWK_CT" "$_arp" "$_n6" "$_seen" "$_prev" "$_acc" "$PA_CT_FILE" 2>/dev/null)
  rm -f "$PA_TMP.n6"
  if ! pa_isnum "${1:-}" || ! pa_isnum "${2:-}" || ! pa_isnum "${3:-}"; then
    rm -f "$PA_TMP.ct.new" "$PA_TMP.ctacc.new" "$PA_TMP.seen.new"
    return 0
  fi
  mv -f "$PA_TMP.ct.new" "$PA_TMP.ct"
  [ -f "$PA_TMP.ctacc.new" ] && mv -f "$PA_TMP.ctacc.new" "$PA_TMP.ctacc"
  [ -f "$PA_TMP.seen.new" ] && mv -f "$PA_TMP.seen.new" "$PA_TMP.seen"
  PA_CT_FLOWS=$1
  # Counts on any connection, or the switch on (connections opened before it was
  # turned on carry none): counting. Neither: the kernel keeps no counts.
  pa_read _acct "$PA_ROOT/proc/sys/net/netfilter/nf_conntrack_acct"
  if [ "$1" -gt 0 ] || [ "$_acct" = 1 ]; then
    PA_CT_STATE=ok
  else
    PA_CT_STATE=off
  fi
  return 0
}


# -- The report --------------------------------------------------------------------

# JSON string escaping for the awk programs. A character loop rather than gsub,
# because gsub's handling of backslashes in the replacement differs between BusyBox
# awk and GNU awk, and a hostname with a quote in it must not break the report.
PA_AWK_ESC='
function esc(s,    out, i, c) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c < " " || c == "\177") continue
    else out = out c
  }
  return out
}
'

# The awk pass that turns everything into the Firestore write: the router map
# (keys from FirestoreSchema.Router), plus lastSeenAt and appVersion. Strings from
# the network (hostnames, SSIDs) only reach JSON through esc(); scalars arrive in
# the environment rather than via -v, which would interpret their backslashes.
# Fields with nothing to say are left out, which both owner clients read as null.
PA_AWK_REPORT='
function fstr(s) { return (s == "") ? "" : "{\"stringValue\":\"" esc(s) "\"}" }
function fint(n) { return (n ~ /^-?[0-9]+$/) ? "{\"integerValue\":\"" n "\"}" : "" }
function fdbl(n) { return (n ~ /^-?[0-9]+(\.[0-9]+)?$/) ? "{\"doubleValue\":" n "}" : "" }
function put(acc, name, v) { if (v == "") return acc; if (acc != "") acc = acc ","; return acc "\"" name "\":" v }
function fmap(fields) { return "{\"mapValue\":{\"fields\":{" fields "}}}" }
function farr(values) { return (values == "") ? "{\"arrayValue\":{}}" : "{\"arrayValue\":{\"values\":[" values "]}}" }
function ms(x) { return sprintf("%.0f", x) }
function bandname(b) {
  if (b == "2") return "BAND_2_4GHZ"
  if (b == "5") return "BAND_5GHZ"
  if (b == "6") return "BAND_6GHZ"
  if (b == "w") return "WIRED"
  return ""
}
function remember(m) { if (!(m in known)) { known[m] = 1; order[++n] = m } }
function flush() {
  if (cur != "" && macok(cur)) {
    sig = (savg != "") ? savg : ((ssig != "") ? ssig : santa)
    wband[cur] = curband; wsig[cur] = sig; wct[cur] = sct
    if (sdn ~ /^[0-9]+$/ && sup ~ /^[0-9]+$/) { wdn[cur] = sdn; wup[cur] = sup }
    wld[cur] = sld; wlu[cur] = slu
    # What the driver gave, counted once per station: the capabilities and doctor.
    if (!(cur in probed)) {
      probed[cur] = 1; nsta++
      if (sig != "") nsig++
      if (cur in wdn) ndata++
      if (sld + 0 > 0 || slu + 0 > 0) nrate++
    }
    remember(cur)
    if (!(cur in counted)) { counted[cur] = 1; rcount[curparent]++ }
  }
  cur = ""; savg = ""; ssig = ""; sct = ""; santa = ""; sdn = ""; sup = ""; sld = ""; slu = ""; tdtot = 0
}
# Bytes a station moved since the previous report, from two readings of a counter
# that starts again at 0 when it reconnects. A smaller reading while it stayed
# connected is a 32-bit counter that wrapped (old Broadcom drivers); otherwise it
# reconnected, and everything since then counts.
function grew(now, before, ct, pct) {
  if (now + 0 >= before + 0) return now - before
  if (ct ~ /^[0-9]+$/ && pct ~ /^[0-9]+$/ && ct + 0 >= pct + 0 && before + 0 >= 2147483648 && before + 0 < 4294967296) return now + 4294967296 - before
  return now + 0
}
# A link rate in Mbit/s. Under 6.5 (the slowest 802.11n data rate) is a keep-alive
# or a management frame sent at a basic rate, which says nothing about the link.
function mbps(v) { return (v + 0 >= 6.5) ? sprintf("%.0f", v + 0) : "" }
function capadd(acc, name) { if (acc != "") acc = acc ","; return acc fstr(name) }
FILENAME == leases {
  m = tolower($2)
  if (macok(m)) { lip[m] = $3; if ($4 != "*" && $4 != "") lname[m] = $4 }
  next
}
FILENAME == names {
  split($0, f, "\t")
  m = tolower(f[1])
  if (macok(m) && f[2] != "") uname[m] = f[2]
  next
}
FILENAME == arp {
  if (FNR == 1) next
  m = tolower($4)
  if (($3 != "0x2" && $3 != "0x6") || !macok(m) || !lanok($6)) next
  aip[m] = $1; remember(m)
  next
}
FILENAME == prevsurvey {
  pact[$1] = $2; pbusy[$1] = $3
  next
}
FILENAME == prevsta {
  # "@ SECONDS": when the previous report read the stations, even if none were there.
  if ($1 == "@" && $2 ~ /^[0-9]+$/) lastat = $2 + 0
  else if (macok($1) && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/) {
    pdn[$1] = $2; pup[$1] = $3; pct[$1] = $4; pat[$1] = $5
  }
  next
}
FILENAME == usage {
  if ($1 ~ /^[0-9]+$/ && macok($2) && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/) { k = $1 " " $2; udn[k] += $3; uup[k] += $4 }
  next
}
# What the connections of each device moved since the previous report, from the
# connection table: "@ SECONDS" (when that window began), then "MAC DOWN UP".
FILENAME == ctacc {
  if ($1 == "@" && $2 ~ /^[0-9]+$/) ctfrom = $2 + 0
  else if (macok($1) && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/) { cdn[$1] = $2; cup[$1] = $3 }
  next
}
# When the agent saw each device join, from its reads of the tables: "MAC SECONDS
# LASTSEEN", or "-" for one that was there before it could tell.
FILENAME == joins {
  if (macok($1) && $2 ~ /^[0-9]+$/) jfirst[$1] = $2
  next
}
FILENAME == history {
  if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/) { nh++; hat[nh] = $1; hrx[nh] = $2; htx[nh] = $3 }
  next
}
FILENAME == wifi {
  if ($0 ~ /^@RADIO\t/) {
    flush(); mode = ""
    k = split($0, f, "\t")
    nr++; rif[nr] = f[2]; rband[nr] = f[3]; rch[nr] = f[4]; rw[nr] = f[5]
    s = f[6]; for (i = 7; i <= k; i++) s = s " " f[i]
    rssid[nr] = s
    next
  }
  if ($0 ~ /^@IF\t/) { flush(); split($0, f, "\t"); curif = f[2]; curband = f[3]; curparent = f[4]; mode = ""; next }
  if ($0 ~ /^@STA\t/) { flush(); split($0, f, "\t"); cur = tolower(f[2]); mode = "wl"; next }
  if ($0 ~ /^@SURVEY\t/) { flush(); split($0, f, "\t"); sif = f[2]; mode = "survey"; inuse = 0; next }
  if ($0 ~ /^@CHANIM\t/) { flush(); split($0, f, "\t"); cif = f[2]; mode = "chanim"; cidx = 0; next }
  if ($1 == "Station") { flush(); cur = tolower($2); mode = "iw"; next }
  # Broadcom `wl chanim_stats`: a header naming the columns, then one sample per
  # line, the newest last. The channel was busy for whatever share was not idle.
  # A sample starts with its chanspec: in hex on older drivers (0x1006, the
  # RT-N18U), as the channel itself from version 4 on (11, 36/80, the RT-AX86U
  # Pro). Version 4 also runs its busy column into the timestamp ("17" "18306624"
  # printed as 1718306624), so busy is worked out from idle, which stays put. Two
  # patterns, not /^(0x)?[0-9]/: GNU awk 5.4 matches that only when the 0x is there.
  if (mode == "chanim") {
    if ($1 == "chanspec") { for (i = 1; i <= NF; i++) if ($i == "idle") cidx = i }
    else if (cidx > 0 && ($1 ~ /^0x/ || $1 ~ /^[0-9]/) && $cidx ~ /^[0-9]+$/) {
      v = 100 - $cidx; if (v < 0) v = 0; if (v > 100) v = 100
      cbusy[cif] = v
    }
    next
  }
  if (mode == "survey") {
    if ($0 ~ /frequency:/) inuse = ($0 ~ /in use/)
    else if (inuse && $0 ~ /channel active time:/) sact[sif] = $4
    else if (inuse && $0 ~ /channel busy time:/) sbusy[sif] = $4
    next
  }
  if (cur == "") next
  if (mode == "iw") {
    if ($1 == "signal" && $2 == "avg:") savg = $3
    else if ($1 == "signal:") ssig = $2
    else if ($1 == "connected" && $2 == "time:") sct = $3
    # From the router side: what it sent the device is what the device downloaded.
    else if ($1 == "tx" && $2 == "bytes:") sdn = $3
    else if ($1 == "rx" && $2 == "bytes:") sup = $3
    else if ($1 == "tx" && $2 == "bitrate:") sld = $3
    else if ($1 == "rx" && $2 == "bitrate:") slu = $3
  } else if (mode == "wl") {
    if ($1 == "in" && $2 == "network") sct = $3
    else if ($1 == "tx" && $2 == "total" && $3 == "bytes:") { sdn = $4; tdtot = 1 }
    # Older drivers (the RT-N18U) have no total, only data bytes: the same count.
    else if ($1 == "tx" && $2 == "data" && $3 == "bytes:") { if (!tdtot) sdn = $4 }
    else if ($1 == "rx" && $2 == "data" && $3 == "bytes:") sup = $4
    else if ($0 ~ /rate of last tx pkt:/) { v = $0; sub(/.*pkt:[ \t]*/, "", v); sld = (v + 0) / 1000 }
    else if ($0 ~ /rate of last rx pkt:/) { v = $0; sub(/.*pkt:[ \t]*/, "", v); slu = (v + 0) / 1000 }
    else if ($0 ~ /smoothed rssi:/) { v = $0; sub(/.*smoothed rssi:[ \t]*/, "", v); savg = v + 0 }
    else if ($0 ~ /per antenna average rssi of rx data frames:/) {
      v = $0; sub(/.*frames:[ \t]*/, "", v); c = split(v, a, " "); t = 0; q = 0
      for (i = 1; i <= c; i++) if (a[i] + 0 < 0) { t += a[i]; q++ }
      if (q > 0) santa = int(t / q)
    }
  }
  next
}
END {
  flush()
  now = ENVIRON["PJ_NOW_MS"] + 0

  # Radios, with airtime from the survey counters since the previous report
  # (OpenWrt), or from the driver channel-utilisation sample (Broadcom).
  radios = ""
  for (i = 1; i <= nr; i++) {
    r = rif[i]; util = ""
    if ((r in sact) && (r in pact) && sact[r] > pact[r]) {
      util = int(100 * (sbusy[r] - pbusy[r]) / (sact[r] - pact[r]))
      if (util < 0) util = 0; if (util > 100) util = 100
    }
    if (r in sact) { printf("%s %s %s\n", r, sact[r], sbusy[r]) > surveyout; nsurv++ }
    else if (r in cbusy) { util = cbusy[r]; nsurv++ }
    x = ""
    x = put(x, "band", fstr(bandname(rband[i])))
    x = put(x, "ssid", fstr(rssid[i]))
    x = put(x, "channel", fint(rch[i]))
    x = put(x, "widthMhz", fint(rw[i]))
    x = put(x, "utilizationPercent", fint(util))
    x = put(x, "clientCount", fint((r in rcount) ? rcount[r] : 0))
    if (radios != "") radios = radios ","
    radios = radios fmap(x)
  }
  close(surveyout)

  # Data each Wi-Fi device used: what its counters grew by since the previous
  # report goes into the bucket for this hour, and the last 24 hourly buckets are kept
  # (in RAM, like the history). A device first seen after the previous report
  # joined since, so all of its counter counts; one already connected when the
  # counting began only counts from here. Every device, not only the ones listed.
  nows = int(now / 1000); hour = int(nows / 3600)
  printf("@ %s\n", nows) > staout
  for (i = 1; i <= n; i++) {
    m = order[i]
    if (!(m in wdn)) continue
    dd = 0; du = 0
    if (m in pdn) {
      dd = grew(wdn[m], pdn[m], wct[m], pct[m]); du = grew(wup[m], pup[m], wct[m], pct[m])
      dt = nows - pat[m]
      if (dt > 0 && dt <= 3600) { rdn[m] = sprintf("%.0f", dd * 8 / dt); rup[m] = sprintf("%.0f", du * 8 / dt) }
    } else if (lastat > 0 && wct[m] ~ /^[0-9]+$/ && wct[m] + 0 <= nows - lastat) {
      dd = wdn[m] + 0; du = wup[m] + 0
    }
    k = hour " " m; udn[k] += dd; uup[k] += du
    printf("%s %s %s %s %s\n", m, wdn[m], wup[m], wct[m], nows) > staout
  }
  close(staout)
  # Every device on none of the radios (wired, or behind an extender) the same way,
  # from what its connections moved since the previous report. A device on a radio
  # is counted by its station counters above, never twice.
  ctok = (ENVIRON["PJ_CT"] == "ok" || ENVIRON["PJ_CT"] == "busy")
  cdt = (ctfrom > 0) ? nows - ctfrom : 0
  for (m in cdn) {
    if ((m in wband) || cdn[m] + cup[m] == 0) continue
    k = hour " " m; udn[k] += cdn[m]; uup[k] += cup[m]
  }
  for (i = 1; i <= n; i++) if (!(order[i] in wband)) { nwired++; if (order[i] in jfirst) nwjoin++ }
  for (k in udn) {
    split(k, kk, " ")
    if (kk[1] + 0 > hour - 24 && kk[1] + 0 <= hour) {
      printf("%s %s %.0f %.0f\n", kk[1], kk[2], udn[k], uup[k]) > usageout
      tdn[kk[2]] += udn[k]; tup[kk[2]] += uup[k]
    }
  }
  close(usageout)

  clients = ""; shown = 0
  for (i = 1; i <= n && shown < maxc; i++) {
    m = order[i]
    x = ""
    x = put(x, "mac", fstr(m))
    x = put(x, "name", fstr((m in uname) ? uname[m] : lname[m]))
    x = put(x, "ip", fstr((m in aip) ? aip[m] : lip[m]))
    x = put(x, "band", fstr(bandname((m in wband) ? wband[m] : "")))
    x = put(x, "signalDbm", fint(wsig[m]))
    wired = !(m in wband)
    if (wct[m] ~ /^[0-9]+$/) x = put(x, "connectedSince", fint(ms(now - wct[m] * 1000)))
    # A wired device: when the agent saw it join, since no table on a router keeps that.
    else if (wired && (m in jfirst)) x = put(x, "connectedSince", fint(ms(jfirst[m] * 1000)))
    if (wired && ctok && cdt > 0 && cdt <= 3600) {
      rdn[m] = sprintf("%.0f", cdn[m] * 8 / cdt); rup[m] = sprintf("%.0f", cup[m] * 8 / cdt)
    }
    x = put(x, "downBps", fint(rdn[m]))
    x = put(x, "upBps", fint(rup[m]))
    if ((m in wdn) || (wired && ctok)) {
      x = put(x, "downBytes24h", fint(sprintf("%.0f", tdn[m] + 0)))
      x = put(x, "upBytes24h", fint(sprintf("%.0f", tup[m] + 0)))
    }
    x = put(x, "linkDownMbps", fint(mbps(wld[m])))
    x = put(x, "linkUpMbps", fint(mbps(wlu[m])))
    if (shown) clients = clients ","
    clients = clients fmap(x)
    shown++
  }

  # Traffic history, kept here because there is no server to keep it: the stored
  # samples younger than four hours, this one added when the last is old enough
  # that a fast-tier burst cannot crowd out the hours, the newest 48 kept. A new
  # sample is the average since the previous one (avgrx/avgtx), not the rate of this report.
  kept = 0
  for (i = 1; i <= nh; i++) {
    if (hat[i] + 0 <= now && now - hat[i] <= hage * 1000) { kept++; kat[kept] = hat[i]; krx[kept] = hrx[i]; ktx[kept] = htx[i] }
  }
  rx = ENVIRON["PJ_RX"]; tx = ENVIRON["PJ_TX"]
  avgrx = ENVIRON["PJ_HRX"]; avgtx = ENVIRON["PJ_HTX"]
  if (avgrx ~ /^[0-9]+$/ && avgtx ~ /^[0-9]+$/ && (kept == 0 || now - kat[kept] >= hspace * 1000)) {
    kept++; kat[kept] = ms(now); krx[kept] = avgrx; ktx[kept] = avgtx
    print ms(now) > histadded
    close(histadded)
  }
  hist = ""
  for (i = (kept > hmax ? kept - hmax + 1 : 1); i <= kept; i++) {
    printf("%s %s %s\n", kat[i], krx[i], ktx[i]) > histout
    x = ""
    x = put(x, "at", fint(kat[i]))
    x = put(x, "rx", fint(krx[i]))
    x = put(x, "tx", fint(ktx[i]))
    if (hist != "") hist = hist ","
    hist = hist fmap(x)
  }
  close(histout)

  rt = ""
  rt = put(rt, "capturedAt", fint(ms(now)))
  rt = put(rt, "bootedAt", fint(ENVIRON["PJ_BOOTED"]))
  rt = put(rt, "cpuPercent", fint(ENVIRON["PJ_CPU"]))
  rt = put(rt, "memoryUsedBytes", fint(ENVIRON["PJ_MU"]))
  rt = put(rt, "memoryTotalBytes", fint(ENVIRON["PJ_MT"]))
  rt = put(rt, "temperatureC", fint(ENVIRON["PJ_TC"]))
  rt = put(rt, "fanRpm", fint(ENVIRON["PJ_FAN"]))
  rt = put(rt, "wanUpSince", fint(ENVIRON["PJ_WANUP"]))
  rt = put(rt, "wanPublicIp", fstr(ENVIRON["PJ_WIP"]))
  rt = put(rt, "wanIsp", fstr(ENVIRON["PJ_ISP"]))
  rt = put(rt, "wanType", fstr(ENVIRON["PJ_WT"]))
  rt = put(rt, "wanLocation", fstr(ENVIRON["PJ_LOC"]))
  rt = put(rt, "wanLastOutageStartedAt", fint(ENVIRON["PJ_OA"]))
  rt = put(rt, "wanLastOutageEndedAt", fint(ENVIRON["PJ_OB"]))
  rt = put(rt, "wanRxBps", fint(rx))
  rt = put(rt, "wanTxBps", fint(tx))
  rt = put(rt, "wanHistory", farr(hist))
  rt = put(rt, "clientCount", fint(n + 0))
  rt = put(rt, "clientUsageSince", fint(ENVIRON["PJ_USINCE"]))
  rt = put(rt, "clients", farr(clients))
  rt = put(rt, "radios", farr(radios))
  # What this router lets the agent measure, so the apps can say what it cannot
  # rather than leave a figure blank. From what the tools gave, before any of it
  # was filtered: a device whose link rates were all keep-alives still has them.
  # The Wi-Fi client ones are only known while a Wi-Fi device is connected; the
  # wired one is the connection table itself, so it is known with nobody wired.
  caps = ""
  if (ENVIRON["PJ_TC"] != "") caps = capadd(caps, "TEMPERATURE")
  if (nsurv > 0) caps = capadd(caps, "AIRTIME")
  if (nsig > 0) caps = capadd(caps, "CLIENT_SIGNAL")
  if (ndata > 0) caps = capadd(caps, "CLIENT_DATA")
  if (nrate > 0) caps = capadd(caps, "CLIENT_LINK_RATE")
  if (ctok) caps = capadd(caps, "WIRED_CLIENT_DATA")
  rt = put(rt, "capabilities", farr(caps))
  if (probeout != "") {
    printf("stations %d\nsignal %d\ndata %d\nrate %d\nradios %d\nairtime %d\nwired %d\nwiredjoin %d\n", nsta, nsig, ndata, nrate, nr, nsurv, nwired, nwjoin) > probeout
    close(probeout)
  }
  # This agent answers an Update from the owner: the apps offer one only to an agent that says so.
  rt = put(rt, "selfUpdate", "{\"booleanValue\":true}")

  stamp = "{\"timestampValue\":\"" ENVIRON["PJ_ISO"] "\"}"
  out = ""
  out = put(out, "router", fmap(rt))
  out = put(out, "lastSeenAt", stamp)
  out = put(out, "appVersion", fstr(ENVIRON["PJ_AG"]))
  # A router has only a coarse, IP-based position. It rides the very fields a
  # phone GPS fix uses, so the owner map and its accuracy disc place the router
  # as a wide somewhere-in-this-area circle with no router-specific client code.
  # The shell keeps the PATCH updateMask in step with whether these were emitted.
  if (fdbl(ENVIRON["PJ_LAT"]) != "" && fdbl(ENVIRON["PJ_LON"]) != "") {
    out = put(out, "latitude", fdbl(ENVIRON["PJ_LAT"]))
    out = put(out, "longitude", fdbl(ENVIRON["PJ_LON"]))
    out = put(out, "accuracyMeters", fdbl(ENVIRON["PJ_ACC"]))
    out = put(out, "positionSource", fstr(ENVIRON["PJ_PSRC"]))
    out = put(out, "locationCapturedAt", stamp)
  }
  if (ENVIRON["PJ_FULFIL"] == "1") out = put(out, "locationRequestFulfilledAt", stamp)
  printf "{\"fields\":{%s}}\n", out
}
'

# Wall-clock time: PA_WALL in epoch seconds and PA_ISO as RFC 3339, from one fork.
pa_wall() {
  if [ -n "${PA_FAKE_EPOCH:-}" ]; then
    PA_WALL=$PA_FAKE_EPOCH
    PA_ISO=$(date -u -d "@$PA_FAKE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
    return 0
  fi
  # shellcheck disable=SC2046
  set -- $(date -u '+%s %Y-%m-%dT%H:%M:%SZ')
  PA_WALL=$1
  PA_ISO=$2
  if ! pa_isnum "$PA_WALL"; then
    # A C library whose date formats have no %s: work the seconds out from the date.
    PA_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    pa_epoch PA_WALL "$PA_ISO"
  fi
  pa_isnum "$PA_WALL" || PA_WALL=0
}

# Whether an address is one the internet could see: not private, carrier-grade
# NAT, loopback or link-local.
pa_is_public() {
  case $1 in
    '' | 10.* | 127.* | 0.* | 169.254.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 1 ;;
    100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) return 1 ;;
    *:*)
      case $1 in
        fe80* | fc* | fd* | ::1) return 1 ;;
      esac
      return 0
      ;;
    *.*.*.*) return 0 ;;
  esac
  return 1
}

# A decimal coordinate: optional sign, digits, optional fraction. Matched exactly
# as the report builder's `fdbl` matches it, so the shell flag that decides the
# updateMask never disagrees with whether awk actually emitted the coordinate.
pa_is_coord() {
  _c=$1
  case $_c in -*) _c=${_c#-} ;; esac
  case $_c in
    '' | *[!0-9.]* | .* | *. | *.*.*) return 1 ;;
  esac
  return 0
}

# The public address, ISP, city and coordinates, from ipinfo.io, cached for six
# hours or until the router's WAN address changes. Best effort: a router whose
# resolver filters lookup services (NextDNS lists, AdGuard) just reports none, and
# the report still goes out. Sets PA_IP_PUBLIC, PA_ISP, PA_LOC, and PA_LAT/PA_LON
# from the `loc` pair (empty unless both parse as coordinates).
pa_ipinfo() {
  PA_IP_PUBLIC=''
  PA_ISP=''
  PA_LOC=''
  PA_LAT=''
  PA_LON=''
  # Versioned with its line layout. Agents before coordinates wrote five lines to
  # `$PA_TMP.ipinfo`, and /tmp outlives an upgrade: read as-is, that cache would
  # pass for fresh and leave an upgraded router with no position for six hours.
  _cache="$PA_TMP.ipinfo.v2"
  if [ -r "$_cache" ]; then
    {
      read -r _at
      read -r _for
      read -r PA_IP_PUBLIC
      read -r PA_ISP
      read -r PA_LOC
      read -r PA_LAT
      read -r PA_LON
    } < "$_cache"
    if pa_isnum "$_at" && [ "$_for" = "${PA_WAN_IP:-}" ] && [ $((PA_NOW - _at)) -ge 0 ] && [ $((PA_NOW - _at)) -lt 21600 ]; then
      return 0
    fi
  fi
  [ "${PA_DRY:-0}" = 1 ] && return 0
  [ -n "${PA_CURL:-}" ] || return 0
  "$PA_CURL" -fsS --connect-timeout 5 --max-time 8 -o "$PA_TMP.ipinfo.json" "$PA_IPINFO_URL" 2>/dev/null || return 0
  _ip=''
  _org=''
  _city=''
  _country=''
  _loc=''
  # One key per line, as ipinfo prints it: `  "org": "AS36903 Maroc Telecom",`
  # `loc` is `"lat,lon"`, e.g. `  "loc": "33.5731,-7.5898",`.
  while IFS= read -r _l; do
    _v=${_l#*\": \"}
    _v=${_v%\"*}
    case $_l in
      *'"ip":'*) _ip=$_v ;;
      *'"org":'*) _org=$_v ;;
      *'"city":'*) _city=$_v ;;
      *'"country":'*) _country=$_v ;;
      *'"loc":'*) _loc=$_v ;;
    esac
  done < "$PA_TMP.ipinfo.json"
  rm -f "$PA_TMP.ipinfo.json"
  case $_org in
    AS[0-9]*' '*) _org=${_org#* } ;;
  esac
  PA_IP_PUBLIC=$_ip
  PA_ISP=$_org
  PA_LOC=$_city
  [ -n "$_country" ] && PA_LOC="${PA_LOC:+$PA_LOC, }$_country"
  # Split "lat,lon" and keep it only when both halves are real coordinates, so a
  # malformed or empty `loc` leaves the router with no position rather than one at
  # 0,0 off West Africa.
  case $_loc in
    *,*)
      _lat=${_loc%%,*}
      _lon=${_loc#*,}
      if pa_is_coord "$_lat" && pa_is_coord "$_lon"; then
        PA_LAT=$_lat
        PA_LON=$_lon
      fi
      ;;
  esac
  printf '%s\n' "$PA_NOW" "${PA_WAN_IP:-}" "$PA_IP_PUBLIC" "$PA_ISP" "$PA_LOC" \
    "$PA_LAT" "$PA_LON" > "$_cache"
}

# Coordinates fit to send: both decimal, and in range. Firestore's rules refuse a
# whole report whose latitude or longitude is out of range, so one bad value would
# cost the router every other figure too.
pa_valid_position() {
  pa_is_coord "$1" && pa_is_coord "$2" || return 1
  awk -v a="$1" -v o="$2" 'BEGIN { exit !(a + 0 >= -90 && a + 0 <= 90 && o + 0 >= -180 && o + 0 <= 180) }'
}

# -- Wi-Fi positioning ------------------------------------------------------------
# The networks around the router, as "mac signal" lines, for a geolocation service
# to turn into a position the way a phone's Wi-Fi positioning does. Each
# platform scans one radio, the 2.4 GHz one (it hears the most neighbours), and
# prints "mac signal ssid" lines for pa_scan_filter.

# Keeps the networks a position can be built on, as "mac signal", strongest first,
# each once, at most PA_GEO_MAX_APS: a well-formed address and signal; not one that
# asked not to be mapped (an SSID ending in _nomap or _optout); not a locally
# administered address (a phone's hotspot or a randomised one), which moves about
# and would drag the fix with it.
pa_scan_filter() {
  awk '
    {
      mac = tolower($1)
      if (mac !~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/) next
      if (substr(mac, 2, 1) ~ /[26ae]/) next
      sig = $2
      sub(/\..*/, "", sig)
      if (sig !~ /^-[0-9]+$/) next
      s = $0
      sub(/^[^ ]+ [^ ]* ?/, "", s)
      if (tolower(s) ~ /_(nomap|optout)$/) next
      if (seen[mac]++) next
      print mac, sig
    }
  ' | sort -t ' ' -k2,2nr | head -n "$PA_GEO_MAX_APS"
}

pa_wifi_scan_openwrt() {
  pa_have iw || return 0
  # The first 2.4 GHz AP interface, else the first AP interface of any band.
  _gif=$(iw dev 2>/dev/null | awk '
    /^[ \t]*Interface / { name = $2; type = ""; next }
    /^[ \t]*type / { type = $2; next }
    /^[ \t]*channel / {
      if (type != "AP") next
      f = $3
      gsub(/[^0-9]/, "", f)
      if (any == "") any = name
      if (f + 0 < 3000 && pick == "") pick = name
      next
    }
    END { print (pick != "" ? pick : any) }
  ')
  [ -n "$_gif" ] || return 0
  # mac80211 drivers refuse a scan from an AP interface unless it is forced.
  { iw dev "$_gif" scan ap-force 2>/dev/null || iw dev "$_gif" scan 2>/dev/null; } | awk '
    function out() {
      if (mac != "") printf "%s %s %s\n", mac, sig, ssid
      mac = ""
      sig = ""
      ssid = ""
    }
    /^BSS / { out(); mac = $2; sub(/\(.*/, "", mac); next }
    /^[ \t]*signal:/ { sig = $2; next }
    /^[ \t]*SSID:/ { s = $0; sub(/^[ \t]*SSID:[ \t]?/, "", s); ssid = s; next }
    END { out() }
  ' | pa_scan_filter
}

pa_wifi_scan_merlin() {
  pa_have wl || return 0
  _gif=''
  for _gu in 0 1 2 3; do
    pa_nv "wl${_gu}_nband"
    [ "$PA_V" = 2 ] || continue
    pa_nv "wl${_gu}_radio"
    [ "$PA_V" = 0 ] && continue
    pa_nv "wl${_gu}_ifname"
    _gif=$PA_V
    [ -n "$_gif" ] && break
  done
  [ -n "$_gif" ] || return 0
  # `wl scan` starts the scan and returns; the results are read once it is done.
  wl -i "$_gif" scan > /dev/null 2>&1
  sleep "$PA_SCAN_WAIT"
  wl -i "$_gif" scanresults 2>/dev/null | awk '
    /^SSID:/ { s = $0; sub(/^SSID:[ \t]*"?/, "", s); sub(/"[ \t]*$/, "", s); ssid = s; sig = ""; next }
    /RSSI:/ { v = $0; sub(/.*RSSI:[ \t]*/, "", v); sub(/[^-0-9].*/, "", v); sig = v; next }
    /^BSSID:/ { printf "%s %s %s\n", $2, sig, ssid; ssid = ""; sig = ""; next }
  ' | pa_scan_filter
}

pa_wifi_scan() {
  : > "$PA_TMP.scan"
  case $PA_PLATFORM in
    openwrt) pa_wifi_scan_openwrt > "$PA_TMP.scan" ;;
    merlin) pa_wifi_scan_merlin > "$PA_TMP.scan" ;;
  esac
}

# The router's position from the networks around it, through beaconDB's geolocate
# API: the Mozilla Location Service request format, free and keyless. On unless the
# owner switched it off (`wifipos off`). Cached in RAM: located again after
# PA_GEO_MAX_AGE or when the WAN address changes, and after a failure not tried
# again for PA_GEO_RETRY. Sets PA_GEO_LAT, PA_GEO_LON and PA_GEO_ACC (empty without
# a fix) and PA_GEO_NOTE, the last outcome: ok; few (fewer than two usable networks
# around); nofix (beaconDB does not know them); coarse (only a rough answer, vaguer
# than PA_GEO_MAX_ACC); http-CODE; unreachable. Empty when off or not tried yet.
pa_wifigeo() {
  PA_GEO_LAT=''
  PA_GEO_LON=''
  PA_GEO_ACC=''
  PA_GEO_NOTE=''
  [ "${PA_WIFIPOS:-on}" = off ] && return 0
  # A pinned router knows where it is: no scan, and nothing about its neighbours sent.
  pa_valid_position "${PA_PIN_LAT:-}" "${PA_PIN_LON:-}" && return 0
  _gcache="$PA_TMP.wifigeo"
  if [ -r "$_gcache" ]; then
    {
      read -r _gat
      read -r _gfor
      read -r PA_GEO_NOTE
      read -r PA_GEO_LAT
      read -r PA_GEO_LON
      read -r PA_GEO_ACC
    } < "$_gcache"
    _gttl=$PA_GEO_RETRY
    [ "$PA_GEO_NOTE" = ok ] && _gttl=$PA_GEO_MAX_AGE
    if pa_isnum "$_gat" && [ "$_gfor" = "${PA_WAN_IP:-}" ] && [ $((PA_NOW - _gat)) -ge 0 ] &&
      [ $((PA_NOW - _gat)) -lt "$_gttl" ]; then
      return 0
    fi
  fi
  PA_GEO_LAT=''
  PA_GEO_LON=''
  PA_GEO_ACC=''
  # A dry run reports what is cached; it never scans or calls out.
  [ "${PA_DRY:-0}" = 1 ] && return 0
  [ -n "${PA_CURL:-}" ] || return 0
  pa_wifi_scan
  _gn=$(wc -l < "$PA_TMP.scan" 2>/dev/null)
  _gn=$((${_gn:-0} + 0))
  if [ "$_gn" -lt 2 ]; then
    PA_GEO_NOTE=few
  else
    awk '
      BEGIN { printf "{\"considerIp\":false,\"wifiAccessPoints\":[" }
      { printf "%s{\"macAddress\":\"%s\",\"signalStrength\":%s}", (NR > 1 ? "," : ""), $1, $2 }
      END { printf "]}\n" }
    ' "$PA_TMP.scan" > "$PA_TMP.geo.req"
    # Who is asking, as a public service may want to know. Nothing secret in it.
    printf 'User-Agent: protection-agent/%s\n' "${PA_AGENT_VERSION%% *}" > "$PA_TMP.geo.hdr"
    if ! pa_http POST "$PA_GEO_URL" "$PA_TMP.geo.req" application/json "$PA_TMP.geo.hdr"; then
      PA_GEO_NOTE=unreachable
    else
      case $PA_STATUS in
        200)
          pa_compact
          _glat=${PA_J#*\"lat\":}
          _glat=${_glat%%[,\}]*}
          _glon=${PA_J#*\"lng\":}
          _glon=${_glon%%[,\}]*}
          _gacc=${PA_J#*\"accuracy\":}
          _gacc=${_gacc%%[,\}]*}
          PA_GEO_NOTE=nofix
          if pa_valid_position "$_glat" "$_glon" && pa_is_coord "$_gacc"; then
            if awk -v a="$_gacc" -v m="$PA_GEO_MAX_ACC" 'BEGIN { exit !(a + 0 > 0 && a + 0 <= m + 0) }'; then
              PA_GEO_LAT=$_glat
              PA_GEO_LON=$_glon
              PA_GEO_ACC=$_gacc
              PA_GEO_NOTE=ok
            else
              PA_GEO_NOTE=coarse
            fi
          fi
          ;;
        404) PA_GEO_NOTE=nofix ;;
        *) PA_GEO_NOTE="http-$PA_STATUS" ;;
      esac
    fi
    rm -f "$PA_TMP.geo.req" "$PA_TMP.geo.hdr"
  fi
  rm -f "$PA_TMP.scan"
  printf '%s\n' "$PA_NOW" "${PA_WAN_IP:-}" "$PA_GEO_NOTE" "$PA_GEO_LAT" "$PA_GEO_LON" "$PA_GEO_ACC" > "$_gcache"
  [ "$PA_GEO_NOTE" = ok ] || pa_log "Wi-Fi positioning: $PA_GEO_NOTE"
}

# Collects everything and prints the Firestore write for a full report. PA_FULFIL=1
# also marks an owner Refresh answered.
pa_build_report() {
  pa_nvram_snapshot
  pa_wan
  pa_lan_device
  pa_accumulate
  pa_uptime
  pa_cpu
  pa_memory
  pa_temperature
  pa_rates
  pa_leases_file
  pa_static_names
  pa_wifi
  pa_wall
  # The service has just read the connection table for this contact; a dry run reads
  # it here.
  [ "${PA_CT_FRESH:-0}" = 1 ] || pa_ct_sample
  PA_CT_FRESH=0
  pa_ipinfo
  pa_wifigeo
  pa_ms _nowms "$PA_WALL"
  _booted=''
  [ -n "${PA_UP:-}" ] && pa_ms _booted $((PA_WALL - PA_UP))
  # The last outage this router outlived, kept in RAM across agent restarts.
  _oa=''
  _ob=''
  [ -r "$PA_TMP.outage" ] && read -r _oa _ob _rest < "$PA_TMP.outage"
  pa_isnum "$_oa" && pa_isnum "$_ob" || { _oa=''; _ob=''; }
  # When the internet came up: the firmware's figure (OpenWrt keeps one), else the
  # end of the last outage, else the first time the agent ran this boot. Never
  # before the boot itself.
  [ -r "$PA_TMP.since" ] || printf '%s\n' "$_nowms" > "$PA_TMP.since"
  read -r _since < "$PA_TMP.since"
  if [ -n "${PA_WAN_UP:-}" ]; then
    pa_ms _wanup $((PA_WALL - PA_WAN_UP))
  elif [ -n "$_ob" ]; then
    _wanup=$_ob
  else
    _wanup=$_since
  fi
  pa_isnum "$_wanup" || _wanup=''
  if [ -n "$_booted" ] && [ -n "$_wanup" ] && [ "$_wanup" -lt "$_booted" ]; then _wanup=$_booted; fi
  # The public address: the router's own WAN address when the internet can see it
  # (right even when its traffic leaves through a VPN or a Tailscale exit node),
  # else the one ipinfo saw (behind the ISP's NAT).
  _wip=${PA_WAN_IP:-}
  pa_is_public "$_wip" || _wip=$PA_IP_PUBLIC
  _arp="$PA_ROOT/proc/net/arp"
  [ -r "$_arp" ] || _arp=/dev/null
  _prev="$PA_TMP.survey"
  [ -r "$_prev" ] || _prev=/dev/null
  _hist="$PA_TMP.history"
  [ -r "$_hist" ] || _hist=/dev/null
  _sta="$PA_TMP.sta"
  [ -r "$_sta" ] || _sta=/dev/null
  _use="$PA_TMP.usage"
  [ -r "$_use" ] || _use=/dev/null
  _cta="$PA_TMP.ctacc"
  [ -r "$_cta" ] || _cta=/dev/null
  _joins="$PA_TMP.seen"
  [ -r "$_joins" ] || _joins=/dev/null
  # When this boot began counting each device's data: the 24 hours shrink to
  # "since then" until a day has passed. In RAM, so a reboot starts again.
  [ -r "$PA_TMP.usage.since" ] || printf '%s\n' "$PA_WALL" > "$PA_TMP.usage.since"
  read -r _usince < "$PA_TMP.usage.since"
  if pa_isnum "$_usince"; then pa_ms _usince "$_usince"; else _usince=''; fi
  # The position, best source first: the owner's pin (exact, and always wins), the
  # Wi-Fi fix (tens of metres), else the city the IP lookup gave, as a
  # PA_IP_AREA_RADIUS_M area. The flag keeps pa_write_report's updateMask in step,
  # so a report without a position never deletes a good one already on the
  # document; awk's fdbl guard emits exactly the coordinates chosen here, so the
  # two agree.
  _plat=''
  _plon=''
  _pacc=''
  _psrc=''
  if pa_valid_position "${PA_PIN_LAT:-}" "${PA_PIN_LON:-}"; then
    _plat=$PA_PIN_LAT
    _plon=$PA_PIN_LON
    _pacc=$PA_PIN_ACCURACY_M
    if pa_is_coord "${PA_PIN_ACC:-}" && awk -v a="$PA_PIN_ACC" 'BEGIN { exit !(a + 0 > 0) }'; then
      _pacc=$PA_PIN_ACC
    fi
    # PositionSource.DEFAULT: coordinates a person set, not a fix.
    _psrc=DEFAULT
  elif pa_valid_position "${PA_GEO_LAT:-}" "${PA_GEO_LON:-}" && pa_is_coord "${PA_GEO_ACC:-}"; then
    _plat=$PA_GEO_LAT
    _plon=$PA_GEO_LON
    _pacc=$PA_GEO_ACC
    _psrc=WIFI
  elif pa_valid_position "${PA_LAT:-}" "${PA_LON:-}"; then
    _plat=$PA_LAT
    _plon=$PA_LON
    _pacc=$PA_IP_AREA_RADIUS_M
    _psrc=IP_ADDRESS
  fi
  PA_HAS_POSITION=0
  [ -n "$_plat" ] && PA_HAS_POSITION=1
  rm -f "$PA_TMP.history.added"
  PJ_NOW_MS=$_nowms PJ_ISO=$PA_ISO PJ_AG=$PA_AGENT_VERSION PJ_FULFIL=${PA_FULFIL:-0} \
    PJ_BOOTED=$_booted PJ_CPU=${PA_CPU:-} PJ_MU=${PA_MEM_USED:-} PJ_MT=${PA_MEM_TOTAL:-} \
    PJ_TC=${PA_TEMP:-} PJ_FAN=${PA_FAN:-} PJ_WANUP=$_wanup PJ_WIP=$_wip PJ_ISP=$PA_ISP \
    PJ_LOC=$PA_LOC PJ_WT=${PA_WAN_TYPE:-} PJ_OA=$_oa PJ_OB=$_ob \
    PJ_RX=${PA_RX_BPS:-} PJ_TX=${PA_TX_BPS:-} PJ_HRX=${PA_HRX_BPS:-} PJ_HTX=${PA_HTX_BPS:-} \
    PJ_LAT=$_plat PJ_LON=$_plon PJ_ACC=$_pacc PJ_PSRC=$_psrc PJ_USINCE=$_usince PJ_CT=${PA_CT_STATE:-none} \
    awk -v leases="$PA_LEASES" -v names="$PA_TMP.names" -v arp="$_arp" -v wifi="$PA_TMP.wifi" \
      -v prevsurvey="$_prev" -v surveyout="$PA_TMP.survey.new" -v history="$_hist" \
      -v prevsta="$_sta" -v staout="$PA_TMP.sta.new" -v usage="$_use" -v usageout="$PA_TMP.usage.new" \
      -v ctacc="$_cta" -v joins="$_joins" -v probeout="${PA_PROBE_OUT:-}" \
      -v histout="$PA_TMP.history.new" -v histadded="$PA_TMP.history.added" -v lan="$PA_LAN_DEV" -v wan="$PA_WAN_DEV" \
      -v maxc="$PA_MAX_CLIENTS" -v hmax="$PA_HISTORY_MAX" -v hspace="$PA_HISTORY_SPACING" \
      -v hage="$PA_HISTORY_AGE" "$PA_AWK_ESC$PA_AWK_HOST$PA_AWK_REPORT" \
      "$PA_LEASES" "$PA_TMP.names" "$_arp" "$_prev" "$_hist" "$_sta" "$_use" "$_cta" "$_joins" "$PA_TMP.wifi"
  _rc=$?
  [ -f "$PA_TMP.survey.new" ] && mv -f "$PA_TMP.survey.new" "$PA_TMP.survey"
  # The counters and the buckets they fed move on together, written or not: the
  # bytes are counted where they belong whether or not this report reaches Firebase.
  # No buckets left means every device aged out of the day. The wired devices'
  # window is in the buckets now, so the next one starts empty.
  if [ "$_rc" = 0 ]; then
    [ -f "$PA_TMP.sta.new" ] && mv -f "$PA_TMP.sta.new" "$PA_TMP.sta"
    if [ -f "$PA_TMP.usage.new" ]; then mv -f "$PA_TMP.usage.new" "$PA_TMP.usage"; else rm -f "$PA_TMP.usage"; fi
    rm -f "$PA_TMP.ctacc"
  fi
  rm -f "$PA_TMP.sta.new" "$PA_TMP.usage.new"
  [ -n "${PA_PROBE_OUT:-}" ] && cp "$PA_TMP.wifi" "$PA_PROBE_OUT.wifi" 2>/dev/null
  rm -f "$PA_TMP.wifi" "$PA_TMP.names"
  return $_rc
}

# Keeps the history the report just wrote. Separate from building it, so a report
# that never reached Firebase does not count as a sample. When it added a point, the
# next point averages from here.
pa_keep_history() {
  [ -f "$PA_TMP.history.new" ] && mv -f "$PA_TMP.history.new" "$PA_TMP.history"
  if [ -f "$PA_TMP.history.added" ]; then
    rm -f "$PA_TMP.history.added"
    PA_HACC_RX=0
    PA_HACC_TX=0
    PA_HACC_FROM=$PA_NOW
  fi
  return 0
}

# -- HTTP and Firebase ------------------------------------------------------------------

# curl, and only curl: Firestore needs a bearer header and the HTTP status, which
# neither OpenWrt's uclient-fetch nor BusyBox wget can give. The firmware's own
# curl first (Entware's may lack a CA bundle), then any on the PATH.
pa_http_client() {
  PA_CURL=''
  for _c in "$PA_ROOT/usr/sbin/curl" "$PA_ROOT/usr/bin/curl"; do
    if [ -x "$_c" ]; then
      PA_CURL=$_c
      return 0
    fi
  done
  if pa_have curl; then
    PA_CURL=$(pa_which curl)
    return 0
  fi
  return 1
}

# Installs curl where it is missing (stock OpenWrt images ship without it).
pa_ensure_curl() {
  pa_http_client && return 0
  pa_say "Installing curl, which the agent uses to reach Firebase..."
  if pa_have apk; then
    apk update >/dev/null 2>&1
    apk add curl >/dev/null 2>&1
  elif pa_have opkg; then
    opkg update >/dev/null 2>&1
    opkg install curl >/dev/null 2>&1
  fi
  pa_http_client
}

# pa_http METHOD URL BODYFILE CONTENT-TYPE AUTH: the response body lands in
# $PA_TMP.resp and its status in PA_STATUS. AUTH=1 sends the Firebase ID token,
# from a file so it never shows in the process list; an absolute path sends the
# header in that file instead (the beaconDB User-Agent). 0 when any HTTP answer
# came back, 1 when none did.
#
# If the router's own resolver fails (NextDNS or AdGuard restarting, Tailscale's
# MagicDNS unreachable, dnsmasq not up yet at boot), curl retries once over DNS-over-
# HTTPS straight to an IP address, which no local DNS setup can intercept.
pa_http() {
  _m=$1
  _u=$2
  _b=$3
  _ct=$4
  _auth=$5
  rm -f "$PA_TMP.resp"
  set -- -gsS --connect-timeout 10 --max-time 30 -X "$_m" -o "$PA_TMP.resp" -w '%{http_code}'
  case $_auth in
    1) [ -r "$PA_TMP.auth" ] && set -- "$@" -H "@$PA_TMP.auth" ;;
    /*) [ -r "$_auth" ] && set -- "$@" -H "@$_auth" ;;
  esac
  if [ -n "$_b" ]; then set -- "$@" -H "Content-Type: $_ct" --data-binary "@$_b"; fi
  PA_STATUS=$("$PA_CURL" "$@" "$_u" 2>/dev/null)
  _rc=$?
  if [ "$_rc" = 6 ] || [ "$_rc" = 7 ]; then
    PA_STATUS=$("$PA_CURL" "$@" --doh-url https://1.1.1.1/dns-query "$_u" 2>/dev/null)
  fi
  case $PA_STATUS in
    [1-5][0-9][0-9]) return 0 ;;
  esac
  PA_STATUS=000
  return 1
}

# The response, minus whitespace, as PA_J. Only ever applied to Firebase's own
# answers, whose values (tokens, ids, statuses, timestamps) hold no spaces.
pa_compact() {
  PA_J=$(tr -d ' \n\r\t' < "$PA_TMP.resp" 2>/dev/null)
}

# pa_jstr VAR KEY: the string value of "KEY" in PA_J.
pa_jstr() {
  _p="\"$2\":\""
  case $PA_J in
    *"$_p"*) ;;
    *)
      eval "$1=''"
      return 1
      ;;
  esac
  _v=${PA_J#*"$_p"}
  _v=${_v%%\"*}
  eval "$1=\$_v"
}

# pa_fsval VAR FIELD: a Firestore field's value whatever its type:
# "FIELD":{"stringValue":"x"} gives x, "FIELD":{"booleanValue":true} gives true.
pa_fsval() {
  _p="\"$2\":{\""
  case $PA_J in
    *"$_p"*) ;;
    *)
      eval "$1=''"
      return 1
      ;;
  esac
  _rb='}'
  _v=${PA_J#*"$_p"}
  _v=${_v#*\":}
  _v=${_v%%"$_rb"*}
  _v=${_v%%,*}
  _v=${_v#\"}
  _v=${_v%\"}
  eval "$1=\$_v"
}

# pa_epoch VAR RFC3339: epoch seconds, or empty when it is not a timestamp.
# Shell arithmetic rather than `date -d`, which some BusyBox builds lack (Merlin
# on an RT-N18U): days since 1970 from the civil date (Howard Hinnant's
# days_from_civil). The two-digit fields lose a leading zero first, or the
# shell would read 08 and 09 as bad octal.
pa_epoch() {
  _t=${2%%[.Z]*}
  case $_t in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
    *)
      eval "$1=''"
      return 1
      ;;
  esac
  _ey=${_t%%-*}
  _t=${_t#*-}
  _emo=${_t%%-*}
  _t=${_t#*-}
  _ed=${_t%%T*}
  _t=${_t#*T}
  _eh=${_t%%:*}
  _t=${_t#*:}
  _emi=${_t%%:*}
  _es=${_t#*:}
  _emo=${_emo#0}
  _ed=${_ed#0}
  _eh=${_eh#0}
  _emi=${_emi#0}
  _es=${_es#0}
  _ey=$((_ey - (_emo <= 2)))
  _eera=$((_ey / 400))
  _eyoe=$((_ey - _eera * 400))
  _edoy=$(((153 * ((_emo + 9) % 12) + 2) / 5 + _ed - 1))
  _edays=$((_eera * 146097 + _eyoe * 365 + _eyoe / 4 - _eyoe / 100 + _edoy - 719468))
  eval "$1=\$((_edays * 86400 + _eh * 3600 + _emi * 60 + _es))"
}

# Keeps the ID token in a file only root can read, for pa_http's -H @file.
pa_set_token() {
  PA_ID_TOKEN=$1
  PA_TOKEN_AT=$PA_NOW
  pa_write_auth "$1"
}

pa_write_auth() {
  (
    umask 077
    printf 'Authorization: Bearer %s\n' "$1" > "$PA_TMP.auth"
  )
  chmod 600 "$PA_TMP.auth" 2>/dev/null
}

# A new anonymous Firebase account: PA_UID, PA_REFRESH and an ID token.
# 0 done, 1 no answer, 2 refused.
pa_signup() {
  printf '{"returnSecureToken":true}\n' > "$PA_TMP.req"
  pa_http POST "$PA_AUTH_URL?key=$PA_KEY" "$PA_TMP.req" application/json 0 || return 1
  [ "$PA_STATUS" = 200 ] || return 2
  pa_compact
  pa_jstr _tok idToken
  pa_jstr PA_REFRESH refreshToken
  pa_jstr PA_UID localId
  [ -n "$_tok" ] && [ -n "$PA_REFRESH" ] && [ -n "$PA_UID" ] || return 2
  pa_set_token "$_tok"
}

# A fresh ID token from the stored refresh token. 0 done, 1 no answer (or Google
# having a moment), 2 the credential was refused and only setup can mint another.
pa_refresh() {
  printf 'grant_type=refresh_token&refresh_token=%s' "$PA_REFRESH" > "$PA_TMP.req"
  pa_http POST "$PA_TOKEN_URL?key=$PA_KEY" "$PA_TMP.req" application/x-www-form-urlencoded 0 || return 1
  case $PA_STATUS in
    200) ;;
    4[0-9][0-9]) return 2 ;;
    *) return 1 ;;
  esac
  pa_compact
  pa_jstr _tok id_token
  pa_jstr _ref refresh_token
  [ -n "$_tok" ] || return 1
  if [ -n "$_ref" ] && [ "$_ref" != "$PA_REFRESH" ]; then
    PA_REFRESH=$_ref
    pa_save_conf
  fi
  pa_set_token "$_tok"
}

# An ID token young enough to use, refreshing it when due. Same codes as pa_refresh.
pa_token() {
  if [ -n "${PA_ID_TOKEN:-}" ] && [ $((PA_NOW - ${PA_TOKEN_AT:-0})) -ge 0 ] &&
    [ $((PA_NOW - ${PA_TOKEN_AT:-0})) -lt "$PA_TOKEN_LIFE" ]; then
    # Requests send the header file, not the variable: without it they would go
    # out unauthenticated, be refused (403, not 401) and park the agent dormant.
    [ -r "$PA_TMP.auth" ] || pa_write_auth "$PA_ID_TOKEN"
    return 0
  fi
  pa_refresh
}

# Reads its own device document: the standing and the owner's requests, one read.
# Sets PA_S (APPROVED, PENDING_APPROVAL, REJECTED, REMOVED, UNKNOWN, or AUTH when
# the token was refused), and PA_REQ, PA_DONE, PA_ACTIVE as epoch seconds or empty.
# The owner's Update comes as PA_UPD_REQ (epoch seconds) with its timestamp as
# written, PA_UPD_REQ_RAW, and the one last answered, PA_UPD_SERVED_RAW.
# 1 when Firebase could not be reached.
pa_poll() {
  PA_S=UNKNOWN
  PA_REQ=''
  PA_DONE=''
  PA_ACTIVE=''
  PA_PIN_LAT=''
  PA_PIN_LON=''
  PA_PIN_ACC=''
  PA_UPD_REQ=''
  PA_UPD_REQ_RAW=''
  PA_UPD_SERVED_RAW=''
  pa_http GET "$PA_DEVICE_URL?mask.fieldPaths=enrollmentStatus&mask.fieldPaths=locationRequestedAt&mask.fieldPaths=locationRequestFulfilledAt&mask.fieldPaths=ownerActiveAt&mask.fieldPaths=pinnedLatitude&mask.fieldPaths=pinnedLongitude&mask.fieldPaths=pinnedAccuracyMeters&mask.fieldPaths=agentUpdateRequestedAt&mask.fieldPaths=agentUpdateServedAt" '' '' 1 || return 1
  case $PA_STATUS in
    200) ;;
    401)
      PA_ID_TOKEN=''
      PA_S=AUTH
      return 0
      ;;
    # Deleted, or never ours: nothing to report to.
    *) return 0 ;;
  esac
  pa_compact
  pa_fsval _st enrollmentStatus
  case $_st in
    APPROVED | PENDING_APPROVAL | REJECTED | REMOVED) PA_S=$_st ;;
  esac
  pa_fsval _v locationRequestedAt && pa_epoch PA_REQ "$_v"
  pa_fsval _v locationRequestFulfilledAt && pa_epoch PA_DONE "$_v"
  pa_fsval _v ownerActiveAt && pa_epoch PA_ACTIVE "$_v"
  # Where the owner pinned the router, if anywhere: its position from here on.
  pa_fsval PA_PIN_LAT pinnedLatitude
  pa_fsval PA_PIN_LON pinnedLongitude
  pa_fsval PA_PIN_ACC pinnedAccuracyMeters
  # An Update: the raw timestamps too, since the answer echoes the request's own
  # (the server's clock, not the router's) and a new request is one that differs.
  pa_fsval PA_UPD_REQ_RAW agentUpdateRequestedAt && pa_epoch PA_UPD_REQ "$PA_UPD_REQ_RAW"
  pa_fsval PA_UPD_SERVED_RAW agentUpdateServedAt
  return 0
}

# Writes a full report. Only the fields Firestore's rules let a device write.
# 0 written, 1 no answer, 2 refused.
pa_write_report() {
  _mask='updateMask.fieldPaths=router&updateMask.fieldPaths=lastSeenAt&updateMask.fieldPaths=appVersion'
  # Only name the position paths when this report carried a position, so a report
  # built while the IP lookup was down leaves the last good fix in place instead
  # of blanking it (a masked path with no value in the body is a field delete).
  [ "${PA_HAS_POSITION:-0}" = 1 ] && _mask="$_mask&updateMask.fieldPaths=latitude&updateMask.fieldPaths=longitude&updateMask.fieldPaths=accuracyMeters&updateMask.fieldPaths=positionSource&updateMask.fieldPaths=locationCapturedAt"
  [ "$2" = 1 ] && _mask="$_mask&updateMask.fieldPaths=locationRequestFulfilledAt"
  pa_http PATCH "$PA_DEVICE_URL?$_mask" "$1" application/json 1 || return 1
  case $PA_STATUS in
    200) return 0 ;;
    401) PA_ID_TOKEN='' ;;
  esac
  return 2
}

# pa_write_update STATE DETAIL [SERVED]: how the owner's Update is going, one of
# AgentUpdateState's names, with a line for the owner (none clears it: a masked
# path left out of the body is deleted). SERVED, the request's own timestamp,
# marks that request answered. 0 written, 1 no answer, 2 refused.
pa_write_update() {
  _umask='updateMask.fieldPaths=agentUpdateState&updateMask.fieldPaths=agentUpdateDetail'
  [ -n "${3:-}" ] && _umask="$_umask&updateMask.fieldPaths=agentUpdateServedAt"
  PJ_US=$1 PJ_UD=$2 PJ_UV=${3:-} awk "$PA_AWK_ESC"'
    BEGIN {
      printf "{\"fields\":{\"agentUpdateState\":{\"stringValue\":\"%s\"}", esc(ENVIRON["PJ_US"])
      if (ENVIRON["PJ_UD"] != "") printf ",\"agentUpdateDetail\":{\"stringValue\":\"%s\"}", esc(ENVIRON["PJ_UD"])
      if (ENVIRON["PJ_UV"] != "") printf ",\"agentUpdateServedAt\":{\"timestampValue\":\"%s\"}", esc(ENVIRON["PJ_UV"])
      printf "}}\n"
    }' > "$PA_TMP.upd"
  [ -s "$PA_TMP.upd" ] || return 2
  pa_http PATCH "$PA_DEVICE_URL?$_umask" "$PA_TMP.upd" application/json 1
  _wrc=$?
  rm -f "$PA_TMP.upd"
  [ "$_wrc" = 0 ] || return 1
  case $PA_STATUS in
    200) return 0 ;;
    401) PA_ID_TOKEN='' ;;
  esac
  return 2
}

# -- Configuration --------------------------------------------------------------------

pa_valid_project() {
  case $1 in
    '' | *[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

pa_valid_key() {
  case $1 in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

pa_valid_id() {
  case $1 in
    '' | *[!A-Za-z0-9]*) return 1 ;;
  esac
  return 0
}

pa_urls() {
  PA_DOCS="$PA_FS_URL/projects/$PA_PROJECT/databases/(default)/documents"
  PA_DEVICE_URL="$PA_DOCS/trackingGroups/$PA_GROUP/devices/$PA_UID"
}

# The credential: the Firebase project and client key, the group and device ids,
# and the refresh token that signs this router back in. Parsed, never sourced.
pa_load_conf() {
  PA_PROJECT=''
  PA_KEY=''
  PA_GROUP=''
  PA_UID=''
  PA_REFRESH=''
  PA_WIFIPOS=''
  [ -r "$PA_CONF" ] || return 1
  while IFS='=' read -r _k _v; do
    _v=${_v#\'}
    _v=${_v%\'}
    case $_k in
      PA_PROJECT) PA_PROJECT=$_v ;;
      PA_KEY) PA_KEY=$_v ;;
      PA_GROUP) PA_GROUP=$_v ;;
      PA_UID) PA_UID=$_v ;;
      PA_REFRESH) PA_REFRESH=$_v ;;
      # Optional: "off" when the owner turned Wi-Fi positioning off.
      PA_WIFIPOS) [ "$_v" = off ] && PA_WIFIPOS=off ;;
    esac
  done < "$PA_CONF"
  pa_valid_project "$PA_PROJECT" && pa_valid_key "$PA_KEY" && pa_valid_id "$PA_GROUP" &&
    pa_valid_id "$PA_UID" && pa_valid_key "$PA_REFRESH" || return 1
  pa_urls
}

pa_save_conf() {
  mkdir -p "$(dirname "$PA_CONF")" || return 1
  (
    umask 077
    {
      printf '%s\n' "$PA_MARK: written by protection-agent setup. Holds this router's credential."
      printf "PA_PROJECT='%s'\n" "$PA_PROJECT"
      printf "PA_KEY='%s'\n" "$PA_KEY"
      printf "PA_GROUP='%s'\n" "$PA_GROUP"
      printf "PA_UID='%s'\n" "$PA_UID"
      printf "PA_REFRESH='%s'\n" "$PA_REFRESH"
      printf "PA_WIFIPOS='%s'\n" "${PA_WIFIPOS:-}"
    } > "$PA_CONF.tmp"
  ) || return 1
  chmod 600 "$PA_CONF.tmp" 2>/dev/null
  mv -f "$PA_CONF.tmp" "$PA_CONF"
}

# -- Enrolment ------------------------------------------------------------------------

# Joins the group behind a pairing code: the router's device document, created at
# PENDING_APPROVAL exactly as a phone's is, for the owner to approve. Reuses this
# router's Firebase identity when it still works (a re-enrolment after removal),
# else signs in as a new anonymous account. PA_PROJECT and PA_KEY must be set.
pa_enroll() {
  _code=$1
  case $_code in
    [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) pa_die "the pairing code is the 6-digit number shown in the app." ;;
  esac
  pa_http_client || pa_die "curl is missing and could not be installed."
  mkdir -p "$(dirname "$PA_TMP")"
  pa_init_platform
  pa_nvram_snapshot
  pa_identity
  pa_hardware_id
  pa_clock
  pa_wall
  [ "$PA_WALL" -ge "$PA_MIN_EPOCH" ] || pa_die "the router's clock is not set yet (it waits for NTP). Try again in a minute."

  if [ -n "${PA_UID:-}" ] && [ -n "${PA_REFRESH:-}" ] && pa_refresh; then
    :
  else
    pa_signup
    case $? in
      0) ;;
      1) pa_die "could not reach Firebase. Check the router's internet connection and try again." ;;
      *) pa_die "Firebase refused the sign-in. Copy the command again from the app (the key may be wrong)." ;;
    esac
  fi

  pa_http GET "$PA_FS_URL/projects/$PA_PROJECT/databases/(default)/documents/pairingCodes/$_code" '' '' 1 ||
    pa_die "could not reach Firebase. Check the router's internet connection and try again."
  [ "$PA_STATUS" = 200 ] || pa_die "that pairing code is not valid. Copy the command again from the app."
  pa_compact
  pa_fsval PA_GROUP groupId
  pa_valid_id "$PA_GROUP" || pa_die "that pairing code is not valid. Copy the command again from the app."
  pa_http GET "$PA_FS_URL/projects/$PA_PROJECT/databases/(default)/documents/trackingGroups/$PA_GROUP?mask.fieldPaths=active" '' '' 1 ||
    pa_die "could not reach Firebase."
  pa_compact
  pa_fsval _active active
  [ "$_active" = true ] || pa_die "that group is not active. Open the app as its owner and try again."
  pa_urls

  # Named from the maker and model, which the owner can rename in the app.
  PA_ENROLLED_NAME=$(printf '%s %s' "$PA_MF" "$PA_MODEL" | cut -c1-60)
  PA_ENROLLED_NAME=${PA_ENROLLED_NAME# }
  PJ_NAME=$PA_ENROLLED_NAME PJ_MF=$PA_MF PJ_MODEL=$PA_MODEL PJ_FW=$PA_FW PJ_AG=$PA_AGENT_VERSION \
    PJ_HW=${PA_HW:-} PJ_ISO=$PA_ISO \
    awk "$PA_AWK_ESC"'
      function str(k) { return "{\"stringValue\":\"" esc(ENVIRON[k]) "\"}" }
      BEGIN {
        t = "{\"timestampValue\":\"" ENVIRON["PJ_ISO"] "\"}"
        printf "{\"fields\":{\"deviceName\":%s,\"manufacturer\":%s,\"model\":%s,\"androidVersion\":%s,\"appVersion\":%s,", str("PJ_NAME"), str("PJ_MF"), str("PJ_MODEL"), str("PJ_FW"), str("PJ_AG")
        if (ENVIRON["PJ_HW"] != "") printf "\"hardwareId\":%s,", str("PJ_HW")
        printf "\"platform\":{\"stringValue\":\"ROUTER\"},\"enrollmentStatus\":{\"stringValue\":\"PENDING_APPROVAL\"},\"trackingStatus\":{\"stringValue\":\"TRACKING_ACTIVE\"},\"joinedAt\":%s,\"lastSeenAt\":%s}}\n", t, t
      }' > "$PA_TMP.enroll"
  # An empty body would PATCH the document to nothing; never send one.
  [ -s "$PA_TMP.enroll" ] || pa_die "could not build the enrolment (awk failed)."
  pa_http PATCH "$PA_DEVICE_URL" "$PA_TMP.enroll" application/json 1 || pa_die "could not reach Firebase."
  rm -f "$PA_TMP.enroll"
  [ "$PA_STATUS" = 200 ] || pa_die "Firebase refused the enrolment (HTTP $PA_STATUS). The database rules may be older than this agent."
  pa_save_conf || pa_die "could not write $PA_CONF."
}

# One look at the device document, for status and for setup's "already enrolled?".
pa_check() {
  pa_load_conf || return 1
  pa_http_client || return 1
  mkdir -p "$(dirname "$PA_TMP")"
  pa_clock
  pa_token || return 1
  pa_poll || return 1
  if [ "$PA_S" = AUTH ]; then
    pa_refresh || return 1
    pa_poll || return 1
  fi
  return 0
}

# -- Service --------------------------------------------------------------------------

pa_running_pid() {
  pa_read _pid "$PA_PIDFILE" || return 1
  pa_isnum "$_pid" || return 1
  kill -0 "$_pid" 2>/dev/null || return 1
  # A reused pid belonging to something else is not us.
  if [ -r "/proc/$_pid/cmdline" ]; then
    grep -q protection-agent "/proc/$_pid/cmdline" 2>/dev/null || return 1
  fi
  PA_PID=$_pid
  return 0
}

pa_sleep() {
  if [ -n "${PA_SLEEP:-}" ]; then
    $PA_SLEEP "$1"
    return 0
  fi
  # In the background and waited for: a shell runs a trap only once its foreground
  # command ends, so a stop (setup restarting the agent) would otherwise wait out
  # the whole sleep, up to an hour, while the new agent was already running.
  sleep "$1" &
  PA_SLEEP_PID=$!
  wait "$PA_SLEEP_PID"
  PA_SLEEP_PID=''
  return 0
}

# Whether the loop may go round again at once. A few times in a row at most, so
# nothing that keeps asking for another contact can turn into a busy loop.
pa_again() {
  _burst=$((_burst + 1))
  [ "$_burst" -le 3 ] && return 0
  _burst=0
  pa_sleep 10
  return 0
}

# One contact: read the device document, answer an owner's Update if one is
# waiting, then write a full report if one is due: five minutes since the last, an
# owner Refresh waiting, the owner watching the router's page, or the first since
# approval. Sets PA_NEXT, the seconds until the next contact. 1 when Firebase
# could not be reached at all.
pa_contact() {
  pa_token
  case $? in
    1) return 1 ;;
    2)
      pa_log "Firebase refused this router's credential; run setup again"
      PA_NEXT=$PA_DORMANT_INTERVAL
      return 0
      ;;
  esac
  pa_poll || return 1
  if [ "$PA_S" = AUTH ]; then
    pa_refresh || return 1
    pa_poll || return 1
  fi
  case $PA_S in
    APPROVED) ;;
    PENDING_APPROVAL)
      # It read and understood its own document: enough to settle in, with no
      # report to write until it is approved.
      pa_trial_pass
      PA_NEXT=$PA_PENDING_INTERVAL
      PA_LAST_FULL=''
      return 0
      ;;
    *)
      case $PA_S in REJECTED | REMOVED) pa_trial_pass ;; esac
      PA_NEXT=$PA_DORMANT_INTERVAL
      PA_LAST_FULL=''
      return 0
      ;;
  esac
  pa_update_say || return 1
  # The owner's Update: answered once, while the app is still waiting for it.
  if [ -n "$PA_UPD_REQ" ] && [ "$PA_UPD_REQ_RAW" != "$PA_UPD_SERVED_RAW" ] &&
    [ $((PA_WALL - PA_UPD_REQ)) -le "$PA_UPDATE_WINDOW" ]; then
    pa_owner_update
    case $? in
      1) return 1 ;;
      # Replaced. In service the new agent has taken this process over by now;
      # only the tests' stand-in for that comes back here.
      3)
        PA_NEXT=$PA_IDLE_INTERVAL
        return 0
        ;;
    esac
  fi
  _hot=0
  if [ -n "$PA_ACTIVE" ] && [ $((PA_WALL - PA_ACTIVE)) -ge 0 ] && [ $((PA_WALL - PA_ACTIVE)) -le "$PA_HOT_WINDOW" ]; then
    _hot=1
  fi
  PA_FULFIL=0
  if [ -n "$PA_REQ" ] && [ $((PA_WALL - PA_REQ)) -le "$PA_REFRESH_WINDOW" ] &&
    { [ -z "$PA_DONE" ] || [ "$PA_DONE" -lt "$PA_REQ" ]; }; then
    PA_FULFIL=1
  fi
  PA_NEXT=$PA_IDLE_INTERVAL
  [ "$_hot" = 1 ] && PA_NEXT=$PA_HOT_INTERVAL
  _due=$PA_PENDING_FULL
  [ -z "$PA_LAST_FULL" ] && _due=1
  if [ -n "$PA_LAST_FULL" ] && [ $((PA_NOW - PA_LAST_FULL)) -ge "$PA_FULL_INTERVAL" ]; then _due=1; fi
  [ "$_hot" = 1 ] && _due=1
  [ "$PA_FULFIL" = 1 ] && _due=1
  [ "$_due" = 1 ] || return 0
  if ! pa_build_report > "$PA_TMP.body" 2>/dev/null; then
    pa_log "could not build a report"
    return 0
  fi
  pa_write_report "$PA_TMP.body" "$PA_FULFIL"
  case $? in
    0)
      PA_LAST_FULL=$PA_NOW
      PA_PENDING_FULL=0
      pa_keep_history
      pa_rates_reset
      pa_trial_pass
      ;;
    1) return 1 ;;
  esac
  return 0
}

# Stopping (TERM or INT): the files go only while the pid file is still this
# agent's. A stopped agent can finish a request after setup has started its
# successor, and deleting that one's pid file and credential header would leave it
# unauthenticated (an hour dormant) and invisible to `start`, which would then run
# a second copy.
pa_exit() {
  [ -n "${PA_SLEEP_PID:-}" ] && kill "$PA_SLEEP_PID" 2>/dev/null
  _owner=''
  pa_read _owner "$PA_PIDFILE"
  if [ "$_owner" = "$$" ]; then
    rm -f "$PA_PIDFILE" "$PA_TMP.auth" "$PA_TMP.req" "$PA_TMP.resp" "$PA_TMP.body"
  fi
  exit 0
}

# The loop. It never exits on its own while enrolled; a removed or unknown router
# looks again hourly, in case the owner re-approves it.
pa_run() {
  pa_load_conf || pa_die "not enrolled. Run: protection-agent setup CODE PROJECT KEY"
  pa_http_client || pa_die "curl is missing. Run setup again to install it."
  mkdir -p "$(dirname "$PA_TMP")"
  if pa_running_pid && [ "$PA_PID" != "$$" ]; then
    pa_die "already running (pid $PA_PID)."
  fi
  printf '%s\n' "$$" > "$PA_PIDFILE"
  trap pa_exit INT TERM
  # The SSH session that started it closing must not take it down.
  trap '' HUP
  pa_init_platform
  pa_nvram_snapshot
  pa_identity
  pa_wan
  pa_lan_device
  pa_clock
  pa_accumulate
  pa_cpu
  pa_ct_enable
  # Fresh from an update (or back from one that failed): may hand over to the
  # agent this one replaced, here and now.
  pa_trial_begin

  PA_LAST_FULL=''
  PA_PENDING_FULL=1
  PA_ID_TOKEN=''
  _fails=0
  _fail_from=''
  _ever_ok=0
  _loops=0
  _burst=0
  pa_log "started, reporting to Firebase project $PA_PROJECT"
  while :; do
    _loops=$((_loops + 1))
    [ -n "${PA_MAX_LOOPS:-}" ] && [ "$_loops" -gt "$PA_MAX_LOOPS" ] && break
    pa_clock
    if [ "$PA_TRIAL" = 1 ] && [ $((PA_NOW - PA_TRIAL_AT)) -ge "$PA_TRIAL_DEADLINE" ]; then
      pa_rollback "$PA_TRIAL_FROM" "could not report"
    fi
    pa_wall
    # Before NTP has set the clock, every timestamp would be wrong and TLS fails.
    if [ "$PA_WALL" -lt "$PA_MIN_EPOCH" ]; then
      pa_sleep 15
      continue
    fi
    pa_accumulate
    pa_ct_sample
    if pa_contact; then
      pa_clock
      pa_wall
      # Back after a failure long enough to be an outage: keep it (in RAM, so an
      # agent restart does not lose it) and send a full report straight away so
      # the owner sees how long it lasted.
      if [ -n "$_fail_from" ] && [ $((PA_NOW - _fail_from)) -ge "$PA_OUTAGE_MIN" ]; then
        pa_ms _down_ms $((PA_WALL - (PA_NOW - _fail_from)))
        pa_ms _up_ms "$PA_WALL"
        printf '%s %s\n' "$_down_ms" "$_up_ms" > "$PA_TMP.outage"
        pa_log "internet back after $((PA_NOW - _fail_from))s"
        _fail_from=''
        _fails=0
        PA_PENDING_FULL=1
        pa_again && continue
      fi
      _fail_from=''
      _fails=0
      _ever_ok=1
      _burst=0
      pa_sleep "$PA_NEXT"
    else
      pa_clock
      _fails=$((_fails + 1))
      # Only a router that has reached Firebase before can be having an outage;
      # failures at boot, before DNS is up, are just a slow start.
      [ "$_ever_ok" = 1 ] && [ -z "$_fail_from" ] && _fail_from=$PA_NOW
      _wait=15
      _i=1
      while [ "$_i" -lt "$_fails" ] && [ "$_wait" -lt "$PA_BACKOFF_MAX" ]; do
        _wait=$((_wait * 2))
        _i=$((_i + 1))
      done
      [ "$_wait" -gt "$PA_BACKOFF_MAX" ] && _wait=$PA_BACKOFF_MAX
      pa_sleep "$_wait"
    fi
  done
  rm -f "$PA_PIDFILE" "$PA_TMP.auth"
}

# OpenWrt's procd service, through its init script. One function, so the tests can
# stand in for procd.
pa_initd() {
  [ -x "$PA_ROOT/etc/init.d/protection-agent" ] || return 1
  "$PA_ROOT/etc/init.d/protection-agent" "$1"
}

pa_start() {
  pa_load_conf || pa_die "not enrolled. Run: protection-agent setup CODE PROJECT KEY"
  if [ "$PA_PLATFORM" = openwrt ] && [ -x "$PA_ROOT/etc/init.d/protection-agent" ]; then
    pa_initd start
    return $?
  fi
  pa_running_pid && return 0
  mkdir -p "$(dirname "$PA_TMP")"
  # Detached from the SSH session that started it: its own session where BusyBox
  # has setsid, immune to hangup otherwise.
  if pa_have setsid; then
    setsid sh "$PA_BIN" run < /dev/null > /dev/null 2>&1 &
  elif pa_have nohup; then
    nohup sh "$PA_BIN" run < /dev/null > /dev/null 2>&1 &
  else
    sh "$PA_BIN" run < /dev/null > /dev/null 2>&1 &
  fi
  if [ "$PA_PLATFORM" = merlin ] && pa_have cru; then
    # A watchdog: `start` is a no-op while the agent runs, and restarts it if not.
    cru l 2>/dev/null | grep -q "#protection-agent#" \
      || cru a protection-agent "*/10 * * * * $PA_BIN start"
  fi
  return 0
}

pa_stop() {
  if [ "$PA_PLATFORM" = openwrt ]; then
    pa_initd stop 2>/dev/null
  fi
  if pa_running_pid; then
    kill "$PA_PID" 2>/dev/null
    # Gone at once from a sleep; mid-request it finishes the request first. Wait a
    # little so a restart does not overlap, but not for a slow request: pa_exit
    # leaves a successor's files alone either way.
    _w=0
    while [ "$_w" -lt 10 ] && kill -0 "$PA_PID" 2>/dev/null; do
      sleep 1
      _w=$((_w + 1))
    done
  fi
  rm -f "$PA_PIDFILE"
  return 0
}

# -- Self-update ----------------------------------------------------------------------
#
# The owner's Update (or `protection-agent update` in the router's shell) syncs the
# installed agent with the one on GitHub (PA_UPDATE_URL). A file that differs
# replaces it, and the running agent re-executes into the new one in the same
# process. The agent it replaced is kept beside it (.prev), and the new one is on
# trial (.trial) until it writes its first report or reads its standing: dying
# before that PA_TRIAL_STARTS times, or getting nowhere for PA_TRIAL_DEADLINE, it
# gives way to the one it replaced, which tells the owner why. Flash is only
# written when there is a new agent: it, its predecessor and the few-line .trial.

# pa_check_agent FILE: whether FILE is a whole agent that runs here: the first
# line, a version, the last line (a download cut short can still be valid shell),
# valid shell, and its own `version` answering with the version it declares. Sets
# PA_NEW_VERSION.
pa_check_agent() {
  PA_NEW_VERSION=''
  pa_read _cl "$1" || return 1
  [ "$_cl" = '#!/bin/sh' ] || return 1
  _cv=$(sed -n 's/^PA_AGENT_VERSION="\([^"]*\)"$/\1/p' "$1" | head -n 1)
  [ -n "$_cv" ] || return 1
  case $(tail -n 1 "$1") in
    *'pa_main "$@"'*) ;;
    *) return 1 ;;
  esac
  sh -n "$1" 2>/dev/null || return 1
  [ "$(PA_SOURCED=0 sh "$1" version 2>/dev/null)" = "$_cv" ] || return 1
  PA_NEW_VERSION=$_cv
}

# Whether two files hold the same bytes. With neither cmp nor a checksum tool to
# tell, the versions decide.
pa_same() {
  [ -r "$2" ] || return 1
  if pa_have cmp; then
    cmp -s "$1" "$2"
    return
  fi
  for _sum in md5sum sha256sum; do
    if pa_have "$_sum"; then
      [ "$("$_sum" < "$1")" = "$("$_sum" < "$2")" ]
      return
    fi
  done
  [ "$PA_NEW_VERSION" = "$PA_AGENT_VERSION" ]
}

# Installs the checked FILE as the agent: the installed one is kept as .prev, and
# .trial names the two (and counts the new one's starts). Mid-trial, the agent
# from before the trial stays the one kept. The trial file goes first, so a power
# cut after the swap still finds the new agent on trial. 0 done, 1 nothing changed.
pa_swap_agent() {
  _from=$PA_AGENT_VERSION
  _kept=0
  if [ -f "$PA_BIN.prev" ] && [ -r "$PA_BIN.trial" ]; then
    _sk=''
    _sfrom=''
    { read -r _sk; read -r _sn; read -r _sfrom; } < "$PA_BIN.trial"
    if [ "$_sk" = trial ] && [ -n "$_sfrom" ]; then
      _from=$_sfrom
      _kept=1
    fi
  fi
  if [ "$_kept" = 0 ]; then
    rm -f "$PA_BIN.prev"
    if ! cp "$PA_BIN" "$PA_BIN.prev" 2>/dev/null; then
      rm -f "$PA_BIN.prev"
      return 1
    fi
  fi
  if printf 'trial\n0\n%s\n%s\n' "$_from" "$PA_NEW_VERSION" > "$PA_BIN.trial.new" 2>/dev/null &&
    cp "$1" "$PA_BIN.new" 2>/dev/null && chmod 755 "$PA_BIN.new" &&
    mv -f "$PA_BIN.trial.new" "$PA_BIN.trial" && mv -f "$PA_BIN.new" "$PA_BIN"; then
    return 0
  fi
  rm -f "$PA_BIN.new" "$PA_BIN.trial.new"
  [ "$_kept" = 0 ] && rm -f "$PA_BIN.prev" "$PA_BIN.trial"
  return 1
}

# Brings the installed agent in line with the one on GitHub. 0 already the same,
# 3 replaced (PA_NEW_VERSION is installed, on trial), 1 not, with the reason for
# the owner in PA_SYNC_WHY.
pa_sync() {
  PA_SYNC_WHY=''
  _cand="$PA_TMP.agent"
  rm -f "$_cand"
  # A query string of its own on every fetch: GitHub's CDN keeps a raw file for
  # minutes, and a sync has to see main as it is now.
  if ! pa_http GET "$PA_UPDATE_URL?t=$PA_WALL" '' '' 0; then
    PA_SYNC_WHY="could not reach GitHub"
    return 1
  fi
  if [ "$PA_STATUS" != 200 ] || ! mv -f "$PA_TMP.resp" "$_cand"; then
    PA_SYNC_WHY="GitHub answered HTTP $PA_STATUS"
    return 1
  fi
  if ! pa_check_agent "$_cand"; then
    rm -f "$_cand"
    PA_SYNC_WHY="the download was not a working agent"
    return 1
  fi
  if pa_same "$_cand" "$PA_BIN"; then
    rm -f "$_cand"
    return 0
  fi
  if ! pa_swap_agent "$_cand"; then
    rm -f "$_cand"
    PA_SYNC_WHY="no room for it in the router's storage"
    return 1
  fi
  rm -f "$_cand"
  pa_log "agent updated to $PA_NEW_VERSION"
  return 3
}

# Becomes the agent now installed, in this very process, so the pid that procd
# watches and the pid file names stays right. A function, so the tests can stand
# in for it.
pa_reexec() {
  exec sh "$PA_BIN" run
}

# The owner's Update. The request is marked answered before anything else, so an
# agent restarting halfway never takes it up twice. Re-executes into a new agent,
# which reports the update itself. 0 answered, 1 Firebase could not be reached, 3
# replaced (seen only in the tests, where re-executing comes back).
pa_owner_update() {
  pa_write_update UPDATING '' "$PA_UPD_REQ_RAW"
  case $? in
    1) return 1 ;;
    # Refused: database rules older than this agent, so there is nowhere to say
    # how it went. Nothing is done.
    2) return 0 ;;
  esac
  pa_sync
  case $? in
    0)
      PA_UPD_SAY=UP_TO_DATE
      PA_UPD_SAY_DETAIL=$PA_AGENT_VERSION
      ;;
    3)
      pa_reexec
      return 3
      ;;
    *)
      PA_UPD_SAY=FAILED
      PA_UPD_SAY_DETAIL=$PA_SYNC_WHY
      ;;
  esac
  PA_UPD_SAY_CLEAR=0
  pa_update_say
}

# Writes what an update left to say (PA_UPD_SAY, PA_UPD_SAY_DETAIL), once. Kept for
# the next contact when Firebase did not answer: 1 then.
pa_update_say() {
  [ -n "${PA_UPD_SAY:-}" ] || return 0
  pa_write_update "$PA_UPD_SAY" "$PA_UPD_SAY_DETAIL"
  [ $? = 1 ] && return 1
  # A rollback's note is said once. A trial's file stays until the trial is over.
  [ "${PA_UPD_SAY_CLEAR:-0}" = 1 ] && rm -f "$PA_BIN.trial"
  PA_UPD_SAY=''
  PA_UPD_SAY_CLEAR=0
  return 0
}

# At start: whether this agent is fresh from an update, and on trial, or back after
# one that failed. A trial's starts are counted, and one start too many brings back
# the agent it replaced. Sets PA_TRIAL (with PA_TRIAL_FROM and PA_TRIAL_AT), and
# what to tell the owner in PA_UPD_SAY.
pa_trial_begin() {
  PA_TRIAL=0
  PA_UPD_SAY=''
  PA_UPD_SAY_DETAIL=''
  PA_UPD_SAY_CLEAR=0
  [ -r "$PA_BIN.trial" ] || return 0
  _tk=''
  _tn=''
  _tfrom=''
  _tto=''
  _twhy=''
  { read -r _tk; read -r _tn; read -r _tfrom; read -r _tto; read -r _twhy; } < "$PA_BIN.trial"
  if [ "$_tk" = rolledback ]; then
    PA_UPD_SAY=FAILED
    PA_UPD_SAY_DETAIL="$_tto $_twhy, so $_tfrom is back"
    PA_UPD_SAY_CLEAR=1
    return 0
  fi
  # Not a trial of this very agent: an update cut off before the swap.
  if [ "$_tk" != trial ] || [ "$_tto" != "$PA_AGENT_VERSION" ]; then
    rm -f "$PA_BIN.trial" "$PA_BIN.prev"
    return 0
  fi
  pa_isnum "$_tn" || _tn=0
  _tn=$((_tn + 1))
  if [ "$_tn" -gt "$PA_TRIAL_STARTS" ]; then
    pa_rollback "$_tfrom" "kept stopping"
    return 0
  fi
  printf 'trial\n%s\n%s\n%s\n' "$_tn" "$_tfrom" "$_tto" > "$PA_BIN.trial"
  PA_TRIAL=1
  PA_TRIAL_FROM=$_tfrom
  PA_TRIAL_AT=$PA_NOW
  PA_UPD_SAY=UPDATED
  PA_UPD_SAY_DETAIL="$_tfrom to $_tto"
}

# The new agent works: the one it replaced is no longer needed.
pa_trial_pass() {
  [ "${PA_TRIAL:-0}" = 1 ] || return 0
  rm -f "$PA_BIN.trial" "$PA_BIN.prev"
  PA_TRIAL=0
  pa_log "agent $PA_AGENT_VERSION settled in"
}

# pa_rollback FROM WHY: the new agent did not make it. The one it replaced (FROM)
# comes back, with a note for the owner, and takes over this process. With none
# to go back to, this one carries on.
pa_rollback() {
  pa_log "agent $PA_AGENT_VERSION $2; going back to $1"
  PA_TRIAL=0
  if [ -f "$PA_BIN.prev" ] && mv -f "$PA_BIN.prev" "$PA_BIN"; then
    printf 'rolledback\n0\n%s\n%s\n%s\n' "$1" "$PA_AGENT_VERSION" "$2" > "$PA_BIN.trial"
    pa_reexec
    return 0
  fi
  rm -f "$PA_BIN.trial"
}

# `protection-agent update`: the owner's Update, by hand in the router's shell.
pa_update() {
  pa_load_conf || pa_die "not enrolled. Run: protection-agent setup CODE PROJECT KEY"
  [ -n "$PA_ROOT" ] || pa_is_root || pa_die "run this as the router's admin (root) user."
  pa_http_client || pa_die "curl is missing. Run setup again to install it."
  mkdir -p "$(dirname "$PA_TMP")"
  pa_wall
  pa_sync
  case $? in
    0) pa_say "Already up to date ($PA_AGENT_VERSION)." ;;
    3)
      pa_stop
      pa_start || pa_die "updated to $PA_NEW_VERSION, but the service did not start."
      pa_say "Updated the agent from $PA_AGENT_VERSION to $PA_NEW_VERSION."
      ;;
    *) pa_die "could not update: $PA_SYNC_WHY." ;;
  esac
}

# -- Install and remove ---------------------------------------------------------------

pa_install_self() {
  _self=$1
  mkdir -p "$PA_HOME" || return 1
  if [ "$_self" != "$PA_BIN" ]; then
    cp "$_self" "$PA_BIN.new" && mv -f "$PA_BIN.new" "$PA_BIN" || return 1
  fi
  chmod 755 "$PA_BIN"
  # Installed by hand: whatever an update had under way is over.
  rm -f "$PA_BIN.prev" "$PA_BIN.trial" "$PA_BIN.trial.new"
}

pa_autostart_on() {
  case $PA_PLATFORM in
    merlin)
      # Merlin runs /jffs/scripts/services-start at boot, but only with custom
      # scripts enabled. It is a system setting, so say so rather than do it quietly.
      # Read live, not from the snapshot: a setup that keeps its enrolment never
      # takes one, and would otherwise "enable" it (and write flash) every time.
      if [ "$(nvram get jffs2_scripts 2>/dev/null)" != 1 ]; then
        nvram set jffs2_scripts=1 && nvram commit
        pa_say "Enabled 'JFFS custom scripts' (Administration > System), needed to start at boot."
      fi
      _ss="$PA_ROOT/jffs/scripts/services-start"
      mkdir -p "$PA_ROOT/jffs/scripts"
      [ -f "$_ss" ] || printf '#!/bin/sh\n' > "$_ss"
      grep -q "$PA_MARK" "$_ss" 2>/dev/null \
        || printf '%s start %s\n' "$PA_BIN" "$PA_MARK" >> "$_ss"
      chmod 755 "$_ss"
      ;;
    openwrt)
      _init="$PA_ROOT/etc/init.d/protection-agent"
      mkdir -p "$PA_ROOT/etc/init.d"
      cat > "$_init" <<EOF
#!/bin/sh /etc/rc.common
$PA_MARK: installed by 'protection-agent setup'.
START=99
STOP=10
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command $PA_BIN run
	procd_set_param respawn 3600 10 0
	procd_close_instance
}
EOF
      chmod 755 "$_init"
      pa_initd enable 2>/dev/null
      # Keep the agent and its credential across a firmware upgrade, and the
      # service's boot links too: sysupgrade restores the files listed here but
      # not /etc/rc.d, so without the links the agent would survive an upgrade
      # installed yet disabled, and never start again. (Not `_keep`: setup holds
      # its "already approved" verdict in that name across this call.)
      _sysupgrade="$PA_ROOT/etc/sysupgrade.conf"
      for _f in "$PA_CONF" "$PA_BIN" "$_init" \
        "$PA_ROOT/etc/rc.d/S99protection-agent" "$PA_ROOT/etc/rc.d/K10protection-agent"; do
        _f=${_f#"$PA_ROOT"}
        grep -qx "$_f" "$_sysupgrade" 2>/dev/null || printf '%s\n' "$_f" >> "$_sysupgrade"
      done
      ;;
  esac
}

pa_autostart_off() {
  case $PA_PLATFORM in
    merlin)
      _ss="$PA_ROOT/jffs/scripts/services-start"
      [ -f "$_ss" ] && sed -i "/$PA_MARK/d" "$_ss"
      pa_have cru && cru d protection-agent 2>/dev/null
      ;;
    openwrt)
      pa_initd disable 2>/dev/null
      rm -f "$PA_ROOT/etc/init.d/protection-agent"
      _sysupgrade="$PA_ROOT/etc/sysupgrade.conf"
      [ -f "$_sysupgrade" ] && sed -i '/protection-agent/d' "$_sysupgrade"
      ;;
  esac
  return 0
}

# The one command behind the one line the owner pastes: install, enrol, start.
# Running it again upgrades the agent in place and keeps a working enrolment.
# Whether the agent runs as root. Merlin's BusyBox has no `id` (an RT-N18U), so
# the effective uid can come from /proc instead; when neither can tell, the
# setup goes ahead and any step root needs fails on its own.
pa_is_root() {
  if pa_have id; then
    [ "$(id -u)" = 0 ]
    return
  fi
  [ -r "/proc/$$/status" ] || return 0
  while read -r _k _ruid _euid _rest; do
    if [ "$_k" = Uid: ]; then
      [ "$_euid" = 0 ]
      return
    fi
  done < "/proc/$$/status"
  return 0
}

pa_setup() {
  _self=$1
  _code=$2
  _project=$3
  _key=$4
  [ "$PA_PLATFORM" = unknown ] && pa_die "this router is not running Asuswrt-Merlin or OpenWrt."
  [ -n "$PA_ROOT" ] || pa_is_root || pa_die "run this as the router's admin (root) user."
  pa_valid_project "$_project" && pa_valid_key "$_key" ||
    pa_die "usage: protection-agent setup CODE PROJECT KEY. Copy the command again from the app."
  pa_ensure_curl || pa_die "curl is missing and could not be installed. Install curl, then run this again."
  pa_install_self "$_self" || pa_die "could not install to $PA_BIN."
  _keep=0
  if pa_load_conf && [ "$PA_PROJECT" = "$_project" ] && pa_check; then
    case $PA_S in
      APPROVED | PENDING_APPROVAL) _keep=1 ;;
    esac
  fi
  if [ "$_keep" = 1 ]; then
    pa_say "Already enrolled ($PA_S). Updated the agent to $PA_AGENT_VERSION."
  else
    # A credential for another project is no use here; one for this project is
    # reused, so a removed router comes back as itself rather than a duplicate.
    [ "$PA_PROJECT" = "$_project" ] || {
      PA_UID=''
      PA_REFRESH=''
    }
    PA_PROJECT=$_project
    PA_KEY=$_key
    pa_enroll "$_code"
    pa_say "Enrolled as \"${PA_ENROLLED_NAME:-this router}\"."
  fi
  pa_stop
  pa_autostart_on
  pa_start || pa_die "installed, but the service did not start."
  if [ "$_keep" = 1 ] && [ "$PA_S" = APPROVED ]; then
    pa_say "Done. It keeps reporting to your app."
  else
    pa_say "Done. Approve it in the app (pending requests) and it starts reporting within a minute."
  fi
}

# Turns Wi-Fi positioning off on a router (it is then placed by its pin, or else by
# its public IP, and never scans or calls out for it), or back on. Restarts the
# service so the next report uses the new setting. The file is written with the
# service stopped, so a token rotation in the running agent can't write its old
# copy over it.
pa_wifipos() {
  pa_load_conf || pa_die "not enrolled. Run: protection-agent setup CODE PROJECT KEY"
  case ${1:-} in
    on) _gwp='' ;;
    off) _gwp=off ;;
    *) pa_die "usage: protection-agent wifipos off | on" ;;
  esac
  pa_stop
  PA_WIFIPOS=$_gwp
  pa_save_conf || pa_die "could not write $PA_CONF."
  rm -f "$PA_TMP.wifigeo"
  pa_start || pa_die "saved, but the service did not start."
  if [ "$_gwp" = off ]; then
    pa_say "Wi-Fi positioning is off: the router is placed by its pin, or else by its public IP."
  else
    pa_say "Wi-Fi positioning is on: the next report locates the router from the networks around it."
  fi
}

pa_uninstall() {
  pa_stop
  pa_autostart_off
  # Connection byte counting goes back off if the agent was what turned it on.
  [ -f "$PA_TMP.acct-on" ] && printf '0\n' 2>/dev/null > "$PA_ROOT/proc/sys/net/netfilter/nf_conntrack_acct"
  rm -f "$PA_CONF" "$PA_TMP".*
  case $PA_PLATFORM in
    merlin) rm -rf "$PA_HOME" ;;
    *) rm -f "$PA_BIN" "$PA_BIN.new" "$PA_BIN.prev" "$PA_BIN.trial" "$PA_BIN.trial.new" ;;
  esac
  pa_say "Removed. Remove the router from the app too, if you have not already."
}

pa_status() {
  if ! pa_load_conf; then
    pa_say "Not enrolled."
    return 1
  fi
  pa_say "Firebase project: $PA_PROJECT"
  pa_say "Device: $PA_UID (group $PA_GROUP)"
  if pa_running_pid; then pa_say "Service: running (pid $PA_PID)"; else pa_say "Service: stopped"; fi
  if pa_check; then pa_say "Enrolment: $PA_S"; else pa_say "Enrolment: Firebase unreachable"; fi
  _gfall="placed by public IP"
  if pa_valid_position "${PA_PIN_LAT:-}" "${PA_PIN_LON:-}"; then
    pa_say "Position: pinned by the owner at $PA_PIN_LAT, $PA_PIN_LON (wins over Wi-Fi and IP)"
    _gfall="placed by its pin"
  fi
  if [ "${PA_WIFIPOS:-on}" = off ]; then
    pa_say "Wi-Fi positioning: off (turn on with: $PA_BIN wifipos on)"
    return 0
  fi
  _gnote=''
  _gacc=''
  [ -r "$PA_TMP.wifigeo" ] && { read -r _ga; read -r _gf; read -r _gnote; read -r _gl; read -r _go; read -r _gacc; } < "$PA_TMP.wifigeo"
  case $_gnote in
    ok) pa_say "Wi-Fi positioning: on, located to within ${_gacc%%.*} m" ;;
    few) pa_say "Wi-Fi positioning: on, but too few Wi-Fi networks nearby ($_gfall)" ;;
    nofix) pa_say "Wi-Fi positioning: on, but beaconDB doesn't know the networks nearby yet ($_gfall)" ;;
    coarse) pa_say "Wi-Fi positioning: on, but beaconDB only gave a rough position ($_gfall)" ;;
    unreachable) pa_say "Wi-Fi positioning: on, but beaconDB was unreachable ($_gfall)" ;;
    '') pa_say "Wi-Fi positioning: on, not located yet" ;;
    *) pa_say "Wi-Fi positioning: on, last attempt failed: $_gnote ($_gfall)" ;;
  esac
}

# One line of the doctor: a label padded to a column, then what was found.
pa_doc() { printf '%-12s %s\n' "$1" "$2"; }

# Shows what this router lets the agent measure, from one dry-run report: what
# the apps will show, what they cannot, and why. Ends with one station's raw
# output with its MAC addresses hidden, for adding a router model to the tests.
# Sends nothing, and prints no credential.
pa_doctor() {
  PA_DRY=1
  mkdir -p "$(dirname "$PA_TMP")"
  pa_init_platform
  pa_clock
  pa_nvram_snapshot
  pa_identity
  PA_PROBE_OUT="$PA_TMP.probe"
  rm -f "$PA_PROBE_OUT" "$PA_PROBE_OUT.wifi"
  pa_build_report > /dev/null
  rm -f "$PA_TMP.history.new"
  _stations=0 _signal=0 _data=0 _rate=0 _radios=0 _airtime=0 _wired=0 _wjoin=0
  if [ -r "$PA_PROBE_OUT" ]; then
    while read -r _k _v; do
      pa_isnum "$_v" || continue
      case $_k in
        stations) _stations=$_v ;;
        signal) _signal=$_v ;;
        data) _data=$_v ;;
        rate) _rate=$_v ;;
        radios) _radios=$_v ;;
        airtime) _airtime=$_v ;;
        wired) _wired=$_v ;;
        wiredjoin) _wjoin=$_v ;;
      esac
    done < "$PA_PROBE_OUT"
  fi

  pa_say "Protection agent $PA_AGENT_VERSION: what this router can report"
  pa_doc Router: "${PA_MF:+$PA_MF }${PA_MODEL:-unknown model}, ${PA_FW:-unknown firmware}"
  _bb=''
  pa_have busybox && _bb=$(busybox 2>&1 | awk '/^BusyBox v/ { print $1, $2; exit }')
  # Asked of the shell itself: past 2^31 a 32-bit shell wraps, which is why the
  # agent does its large numbers in awk.
  _bits=64
  [ $((2147483647 + 1)) -gt 0 ] || _bits=32
  pa_doc Platform: "$PA_PLATFORM${_bb:+, $_bb}, $_bits-bit shell numbers"
  if pa_load_conf 2>/dev/null; then pa_doc Enrolled: "yes (Firebase project $PA_PROJECT)"; else pa_doc Enrolled: no; fi
  _tools=''
  for _t in curl iw wl nvram uci ip; do
    if pa_have "$_t"; then _tools="$_tools $_t yes,"; else _tools="$_tools $_t no,"; fi
  done
  _tools=${_tools%,}
  pa_doc Tools: "${_tools# }"
  if [ -n "${PA_WAN_DEV:-}" ] && [ -r "$PA_ROOT/sys/class/net/$PA_WAN_DEV/statistics/rx_bytes" ]; then
    pa_doc Internet: "WAN ${PA_WAN_DEV}${PA_WAN_TYPE:+ ($PA_WAN_TYPE)}, traffic counters readable"
  else
    pa_doc Internet: "no WAN interface found: no traffic figures"
  fi
  _health='CPU and memory'
  [ -r "$PA_ROOT/proc/meminfo" ] || _health='CPU (no memory figures)'
  if [ -n "${PA_TEMP:-}" ]; then _health="$_health, temperature $PA_TEMP C"; else _health="$_health, no temperature sensor"; fi
  [ -n "${PA_FAN:-}" ] && _health="$_health, fan $PA_FAN rpm"
  pa_doc Health: "$_health"
  pa_doc Wi-Fi: "$_radios radio(s), $_stations device(s) connected"
  _missing=''
  if [ "$_radios" -gt 0 ]; then
    if [ "$_airtime" -gt 0 ]; then
      pa_doc "  airtime" yes
    else
      pa_doc "  airtime" "no (this router gives the agent no channel survey)"
      _missing="$_missing, Wi-Fi airtime"
    fi
  fi
  [ -n "${PA_TEMP:-}" ] || _missing="$_missing, temperature"
  if [ "$_stations" -gt 0 ]; then
    pa_doc "  signal" "$_signal of $_stations devices"
    pa_doc "  data used" "$_data of $_stations devices"
    pa_doc "  link speed" "$_rate of $_stations devices"
    [ "$_signal" -gt 0 ] || _missing="$_missing, device signal"
    [ "$_data" -gt 0 ] || _missing="$_missing, data per device"
    [ "$_rate" -gt 0 ] || _missing="$_missing, link speed per device"
  else
    pa_say "  (connect a Wi-Fi device to see what the driver gives per device)"
  fi
  # Wired devices: their data comes from the connection table, not a driver.
  case ${PA_CT_STATE:-none} in
    ok) _ct="data used from the connection table ($PA_CT_FLOWS connections counted)" ;;
    busy) _ct="data used, but the connection table is too big to read now ($PA_CT_FLOWS connections, over $PA_CT_MAX)" ;;
    off) _ct="no data used: the router keeps no byte counts per connection (the agent turns them on when it starts)" ;;
    *) _ct="no data used: this firmware has no connection table to read" ;;
  esac
  pa_doc Wired: "$_wired device(s), $_ct"
  # When each joined: seen by the agent itself, so one already there when it began
  # watching (long after boot) has no time until it joins again.
  if [ "$_wired" -gt 0 ]; then
    case ${PA_CT_STATE:-none} in
      ok | off)
        _jn="$_wjoin of $_wired devices"
        [ "$_wjoin" -lt "$_wired" ] && _jn="$_jn (the others were connected before the agent began watching; they get a time when they next join)"
        pa_doc "  joined" "$_jn"
        ;;
    esac
  fi
  case ${PA_CT_STATE:-none} in
    ok | busy) ;;
    *) [ "$_wired" -gt 0 ] && _missing="$_missing, data per wired device" ;;
  esac
  # Connections a router hands to its NAT accelerator skip the counting, which is
  # worth knowing before trusting a small figure.
  _accel=''
  case $PA_PLATFORM in
    merlin)
      pa_nv ctf_disable
      [ "$PA_V" = 0 ] && _accel='NAT acceleration'
      ;;
    openwrt)
      if pa_have uci; then
        _accel=$(uci -q show firewall 2>/dev/null | awk -F= '
          $1 ~ /\.flow_offloading_hw$/ && $2 ~ /1/ { hw = 1 }
          $1 ~ /\.flow_offloading$/ && $2 ~ /1/ { sw = 1 }
          END { if (hw) print "hardware flow offloading"; else if (sw) print "flow offloading" }')
      fi
      ;;
  esac
  if [ -n "$_accel" ] && [ "${PA_CT_STATE:-none}" = ok ]; then
    pa_say "  ($_accel is on: connections it speeds up can be counted short)"
  fi
  if [ -n "$_missing" ]; then pa_doc Unavailable: "${_missing#, }"; else pa_doc Unavailable: "nothing missing"; fi
  # One station, as the driver printed it, every MAC address hidden.
  if [ -s "$PA_PROBE_OUT.wifi" ]; then
    pa_say ''
    pa_say 'One Wi-Fi device as the driver reports it (MAC addresses hidden):'
    awk '
      /^@STA\t/ || /^Station / { if (seen) exit; seen = 1 }
      /^@/ { if (seen && $0 !~ /^@STA\t/) exit; if ($0 !~ /^@STA\t/) next }
      seen {
        line = $0
        gsub(/[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]/, "xx:xx:xx:xx:xx:xx", line)
        if (line !~ /^@/) print "  " line
      }' "$PA_PROBE_OUT.wifi"
  fi
  rm -f "$PA_PROBE_OUT" "$PA_PROBE_OUT.wifi"
}

pa_main() {
  pa_detect_platform
  _cmd=${1:-status}
  [ $# -gt 0 ] && shift
  case $_cmd in
    setup) pa_setup "$0" "$@" ;;
    run) pa_run ;;
    start) pa_start ;;
    stop) pa_stop ;;
    restart)
      pa_stop
      pa_start
      ;;
    status) pa_status ;;
    report)
      # A dry run: reads the router, prints the write, sends nothing.
      PA_DRY=1
      mkdir -p "$(dirname "$PA_TMP")"
      pa_init_platform
      pa_clock
      pa_nvram_snapshot
      pa_identity
      pa_build_report
      rm -f "$PA_TMP.history.new"
      ;;
    wifipos) pa_wifipos "$@" ;;
    doctor) pa_doctor ;;
    update) pa_update ;;
    uninstall) pa_uninstall ;;
    version) pa_say "$PA_AGENT_VERSION" ;;
    *) pa_die "unknown command '$_cmd'. Use setup, start, stop, status, report, wifipos, doctor, update or uninstall." ;;
  esac
}

# Keep this the last line, and `version` printing PA_AGENT_VERSION alone: an
# agent updating itself checks both on the agent it downloads.
[ "${PA_SOURCED:-0}" = 1 ] || pa_main "$@"
