#!/bin/sh
# protection-agent: reports an Asuswrt-Merlin or OpenWrt router to the Protection
# owner app, straight to Firebase. See docs/ROUTER-AGENT.md for the whole contract.
#
#   protection-agent setup CODE PROJECT KEY   install, enrol with a pairing code, start
#   protection-agent start | stop             the background service
#   protection-agent status                   enrolment and service state
#   protection-agent report                   print the report it would write (nothing sent)
#   protection-agent uninstall                stop and remove everything it installed
#
# Written for BusyBox ash and BusyBox awk: POSIX only, no bashisms. It sleeps
# between contacts, reads /proc and /sys with shell builtins, and does its parsing
# in one awk pass per report. It signs in to Firebase anonymously, the way the
# Windows client does, and Firestore's rules let it write nothing but its own
# device document. PROJECT and KEY are the app's own public Firebase client
# settings. It needs curl, which setup installs on OpenWrt when it is missing.
#
# Test hooks: PA_ROOT prefixes every filesystem path it reads or writes,
# PA_SOURCED=1 loads the functions without running anything, and PA_FAKE_EPOCH
# pins the wall clock.

PA_AGENT_VERSION="1.2.0 (3)"
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
# A router's only fix is the city-level one its public IP gives, so the map shows
# an area, not a false point: the coordinates ride the device's own location
# fields with this radius as the accuracy, and the owner clients draw the disc.
# Mirrors TrackingConfig.ROUTER_IP_AREA_RADIUS_M and PositionSource.IP_ADDRESS.
PA_IP_AREA_RADIUS_M="${PA_IP_AREA_RADIUS_M:-25000}"
PA_POSITION_SOURCE=IP_ADDRESS

# -- Small helpers -----------------------------------------------------------------

pa_log() {
  if command -v logger >/dev/null 2>&1; then
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
  elif command -v nvram >/dev/null 2>&1 && [ -d "$PA_ROOT/jffs" ]; then
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
    /^(wan_primary|wan[01]_(ifname|proto|ipaddr)|wl[0-3]_(ifname|nband|ssid|radio)|wl[0-3]\.[1-3]_bss_enabled|lan_ifname|productid|odmpid|buildno|extendno|firmver|lan_hwaddr|jffs2_scripts|custom_clientlist)=/ {
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
  if command -v sha256sum >/dev/null 2>&1; then
    PA_HW=$(printf 'protection-router:%s' "$_mac" | sha256sum)
  elif command -v md5sum >/dev/null 2>&1; then
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
    _d=$((_rx - PA_PREV_RX))
    [ "$_d" -lt 0 ] && _d=$(pa_unwrap "$_d" "$PA_PREV_RX")
    PA_ACC_RX=$((${PA_ACC_RX:-0} + _d))
    PA_HACC_RX=$((${PA_HACC_RX:-0} + _d))
    _d=$((_tx - PA_PREV_TX))
    [ "$_d" -lt 0 ] && _d=$(pa_unwrap "$_d" "$PA_PREV_TX")
    PA_ACC_TX=$((${PA_ACC_TX:-0} + _d))
    PA_HACC_TX=$((${PA_HACC_TX:-0} + _d))
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

# A negative delta: a 32-bit counter wrapped (add 2^32), or the interface was reset
# (count nothing rather than a bogus terabyte).
pa_unwrap() {
  if [ "$2" -lt 4294967296 ]; then
    _w=$(($1 + 4294967296))
    [ "$_w" -ge 0 ] && { printf '%s' "$_w"; return; }
  fi
  printf '0'
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
      PA_HRX_BPS=$((PA_HACC_RX * 8 / _span))
      PA_HTX_BPS=$((PA_HACC_TX * 8 / _span))
    fi
  fi
  [ -n "${PA_ACC_FROM:-}" ] || return 0
  _span=$((PA_NOW - PA_ACC_FROM))
  [ "$_span" -ge 5 ] || return 0
  PA_RX_BPS=$((PA_ACC_RX * 8 / _span))
  PA_TX_BPS=$((PA_ACC_TX * 8 / _span))
}

pa_rates_reset() {
  PA_ACC_RX=0
  PA_ACC_TX=0
  PA_ACC_FROM=$PA_NOW
}

# CPU busy percent since the previous report, from /proc/stat's first line.
pa_cpu() {
  PA_CPU=''
  [ -r "$PA_ROOT/proc/stat" ] || return 0
  read -r _c _u _n _s _i _w _q _sq _st _rest < "$PA_ROOT/proc/stat"
  _total=0
  for _v in "$_u" "$_n" "$_s" "$_i" "$_w" "$_q" "$_sq" "$_st"; do
    pa_isnum "$_v" && _total=$((_total + _v))
  done
  _idle=0
  pa_isnum "$_i" && _idle=$_i
  pa_isnum "$_w" && _idle=$((_idle + _w))
  if [ -n "${PA_CPU_TOTAL:-}" ]; then
    _dt=$((_total - PA_CPU_TOTAL))
    _di=$((_idle - PA_CPU_IDLE))
    if [ "$_dt" -gt 0 ] && [ "$_di" -ge 0 ]; then
      PA_CPU=$(((_dt - _di) * 100 / _dt))
      [ "$PA_CPU" -lt 0 ] && PA_CPU=0
      [ "$PA_CPU" -gt 100 ] && PA_CPU=100
    fi
  fi
  PA_CPU_TOTAL=$_total
  PA_CPU_IDLE=$_idle
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
  PA_MEM_TOTAL=$((_tot * 1024))
  PA_MEM_USED=$(((_tot - _avail) * 1024))
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
  command -v iw >/dev/null 2>&1 || return 0
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
  command -v wl >/dev/null 2>&1 || return 0
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
      command -v uci >/dev/null 2>&1 || return 0
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
function put(acc, name, v) { if (v == "") return acc; return acc (acc == "" ? "" : ",") "\"" name "\":" v }
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
function macok(m) { return m ~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])$/ && m != "00:00:00:00:00:00" }
function remember(m) { if (!(m in known)) { known[m] = 1; order[++n] = m } }
function lanok(dev) {
  if (dev == "" || index(" " wan " ", " " dev " ") > 0) return 0
  if (dev ~ /^br-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$/) return 0
  if (lan != "" && dev == lan) return 1
  return dev ~ /^br/
}
function flush() {
  if (cur != "" && macok(cur)) {
    sig = (savg != "") ? savg : ((ssig != "") ? ssig : santa)
    wband[cur] = curband; wsig[cur] = sig; wct[cur] = sct
    remember(cur)
    if (!(cur in counted)) { counted[cur] = 1; rcount[curparent]++ }
  }
  cur = ""; savg = ""; ssig = ""; sct = ""; santa = ""
}
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
  if ($1 == "Station") { flush(); cur = tolower($2); mode = "iw"; next }
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
  } else if (mode == "wl") {
    if ($1 == "in" && $2 == "network") sct = $3
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

  # Radios, with airtime from the survey counters since the previous report.
  radios = ""
  for (i = 1; i <= nr; i++) {
    r = rif[i]; util = ""
    if ((r in sact) && (r in pact) && sact[r] > pact[r]) {
      util = int(100 * (sbusy[r] - pbusy[r]) / (sact[r] - pact[r]))
      if (util < 0) util = 0; if (util > 100) util = 100
    }
    if (r in sact) printf("%s %s %s\n", r, sact[r], sbusy[r]) > surveyout
    x = ""
    x = put(x, "band", fstr(bandname(rband[i])))
    x = put(x, "ssid", fstr(rssid[i]))
    x = put(x, "channel", fint(rch[i]))
    x = put(x, "widthMhz", fint(rw[i]))
    x = put(x, "utilizationPercent", fint(util))
    x = put(x, "clientCount", fint((r in rcount) ? rcount[r] : 0))
    radios = radios (radios == "" ? "" : ",") fmap(x)
  }
  close(surveyout)

  clients = ""; shown = 0
  for (i = 1; i <= n && shown < maxc; i++) {
    m = order[i]
    x = ""
    x = put(x, "mac", fstr(m))
    x = put(x, "name", fstr((m in uname) ? uname[m] : lname[m]))
    x = put(x, "ip", fstr((m in aip) ? aip[m] : lip[m]))
    x = put(x, "band", fstr(bandname((m in wband) ? wband[m] : "")))
    x = put(x, "signalDbm", fint(wsig[m]))
    if (wct[m] ~ /^[0-9]+$/) x = put(x, "connectedSince", fint(ms(now - wct[m] * 1000)))
    clients = clients (shown ? "," : "") fmap(x)
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
    hist = hist (hist == "" ? "" : ",") fmap(x)
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
  rt = put(rt, "clients", farr(clients))
  rt = put(rt, "radios", farr(radios))

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
  pa_ipinfo
  _nowms=$((PA_WALL * 1000))
  _booted=''
  [ -n "${PA_UP:-}" ] && _booted=$(((PA_WALL - PA_UP) * 1000))
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
    _wanup=$(((PA_WALL - PA_WAN_UP) * 1000))
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
  # The device-level position fields ride this report only when the IP lookup gave
  # real coordinates. The flag keeps pa_write_report's updateMask in step, so a
  # report without a position never deletes a good one already on the document;
  # awk's own fdbl guard uses the same test on the same values, so the two agree.
  PA_HAS_POSITION=0
  if pa_is_coord "${PA_LAT:-}" && pa_is_coord "${PA_LON:-}"; then PA_HAS_POSITION=1; fi
  rm -f "$PA_TMP.history.added"
  PJ_NOW_MS=$_nowms PJ_ISO=$PA_ISO PJ_AG=$PA_AGENT_VERSION PJ_FULFIL=${PA_FULFIL:-0} \
    PJ_BOOTED=$_booted PJ_CPU=${PA_CPU:-} PJ_MU=${PA_MEM_USED:-} PJ_MT=${PA_MEM_TOTAL:-} \
    PJ_TC=${PA_TEMP:-} PJ_FAN=${PA_FAN:-} PJ_WANUP=$_wanup PJ_WIP=$_wip PJ_ISP=$PA_ISP \
    PJ_LOC=$PA_LOC PJ_WT=${PA_WAN_TYPE:-} PJ_OA=$_oa PJ_OB=$_ob \
    PJ_RX=${PA_RX_BPS:-} PJ_TX=${PA_TX_BPS:-} PJ_HRX=${PA_HRX_BPS:-} PJ_HTX=${PA_HTX_BPS:-} \
    PJ_LAT=${PA_LAT:-} PJ_LON=${PA_LON:-} PJ_ACC=$PA_IP_AREA_RADIUS_M PJ_PSRC=$PA_POSITION_SOURCE \
    awk -v leases="$PA_LEASES" -v names="$PA_TMP.names" -v arp="$_arp" -v wifi="$PA_TMP.wifi" \
      -v prevsurvey="$_prev" -v surveyout="$PA_TMP.survey.new" -v history="$_hist" \
      -v histout="$PA_TMP.history.new" -v histadded="$PA_TMP.history.added" -v lan="$PA_LAN_DEV" -v wan="$PA_WAN_DEV" \
      -v maxc="$PA_MAX_CLIENTS" -v hmax="$PA_HISTORY_MAX" -v hspace="$PA_HISTORY_SPACING" \
      -v hage="$PA_HISTORY_AGE" "$PA_AWK_ESC$PA_AWK_REPORT" \
      "$PA_LEASES" "$PA_TMP.names" "$_arp" "$_prev" "$_hist" "$PA_TMP.wifi"
  _rc=$?
  [ -f "$PA_TMP.survey.new" ] && mv -f "$PA_TMP.survey.new" "$PA_TMP.survey"
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
  if command -v curl >/dev/null 2>&1; then
    PA_CURL=$(command -v curl)
    return 0
  fi
  return 1
}

# Installs curl where it is missing (stock OpenWrt images ship without it).
pa_ensure_curl() {
  pa_http_client && return 0
  pa_say "Installing curl, which the agent uses to reach Firebase..."
  if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1
    apk add curl >/dev/null 2>&1
  elif command -v opkg >/dev/null 2>&1; then
    opkg update >/dev/null 2>&1
    opkg install curl >/dev/null 2>&1
  fi
  pa_http_client
}

# pa_http METHOD URL BODYFILE CONTENT-TYPE AUTH: the response body lands in
# $PA_TMP.resp and its status in PA_STATUS. AUTH=1 sends the Firebase ID token,
# from a file so it never shows in the process list. 0 when any HTTP answer came
# back, 1 when none did.
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
  if [ "$_auth" = 1 ] && [ -r "$PA_TMP.auth" ]; then set -- "$@" -H "@$PA_TMP.auth"; fi
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
pa_epoch() {
  _t=${2%%[.Z]*}
  case $_t in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
    *)
      eval "$1=''"
      return 1
      ;;
  esac
  _e=$(date -u -d "${_t%%T*} ${_t#*T}" +%s 2>/dev/null)
  pa_isnum "$_e" || _e=''
  eval "$1=\$_e"
}

# Keeps the ID token in a file only root can read, for pa_http's -H @file.
pa_set_token() {
  PA_ID_TOKEN=$1
  PA_TOKEN_AT=$PA_NOW
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
    return 0
  fi
  pa_refresh
}

# Reads its own device document: the standing and the owner's requests, one read.
# Sets PA_S (APPROVED, PENDING_APPROVAL, REJECTED, REMOVED, UNKNOWN, or AUTH when
# the token was refused), and PA_REQ, PA_DONE, PA_ACTIVE as epoch seconds or empty.
# 1 when Firebase could not be reached.
pa_poll() {
  PA_S=UNKNOWN
  PA_REQ=''
  PA_DONE=''
  PA_ACTIVE=''
  pa_http GET "$PA_DEVICE_URL?mask.fieldPaths=enrollmentStatus&mask.fieldPaths=locationRequestedAt&mask.fieldPaths=locationRequestFulfilledAt&mask.fieldPaths=ownerActiveAt" '' '' 1 || return 1
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
  ${PA_SLEEP:-sleep} "$1"
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

# One contact: read the device document, then write a full report if one is due:
# five minutes since the last, an owner Refresh waiting, the owner watching the
# router's page, or the first since approval. Sets PA_NEXT, the seconds until the
# next contact. 1 when Firebase could not be reached at all.
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
      PA_NEXT=$PA_PENDING_INTERVAL
      PA_LAST_FULL=''
      return 0
      ;;
    *)
      PA_NEXT=$PA_DORMANT_INTERVAL
      PA_LAST_FULL=''
      return 0
      ;;
  esac
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
      ;;
    1) return 1 ;;
  esac
  return 0
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
  trap 'rm -f "$PA_PIDFILE" "$PA_TMP.auth" "$PA_TMP.req" "$PA_TMP.resp" "$PA_TMP.body"; exit 0' INT TERM
  # The SSH session that started it closing must not take it down.
  trap '' HUP
  pa_init_platform
  pa_nvram_snapshot
  pa_identity
  pa_wan
  pa_clock
  pa_accumulate
  pa_cpu

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
    pa_wall
    # Before NTP has set the clock, every timestamp would be wrong and TLS fails.
    if [ "$PA_WALL" -lt "$PA_MIN_EPOCH" ]; then
      pa_sleep 15
      continue
    fi
    pa_accumulate
    if pa_contact; then
      pa_clock
      pa_wall
      # Back after a failure long enough to be an outage: keep it (in RAM, so an
      # agent restart does not lose it) and send a full report straight away so
      # the owner sees how long it lasted.
      if [ -n "$_fail_from" ] && [ $((PA_NOW - _fail_from)) -ge "$PA_OUTAGE_MIN" ]; then
        printf '%s %s\n' "$(((PA_WALL - (PA_NOW - _fail_from)) * 1000))" "$((PA_WALL * 1000))" > "$PA_TMP.outage"
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
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$PA_BIN" run < /dev/null > /dev/null 2>&1 &
  elif command -v nohup >/dev/null 2>&1; then
    nohup sh "$PA_BIN" run < /dev/null > /dev/null 2>&1 &
  else
    sh "$PA_BIN" run < /dev/null > /dev/null 2>&1 &
  fi
  if [ "$PA_PLATFORM" = merlin ] && command -v cru >/dev/null 2>&1; then
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
  fi
  rm -f "$PA_PIDFILE"
  return 0
}

# -- Install and remove ---------------------------------------------------------------

pa_install_self() {
  _self=$1
  mkdir -p "$PA_HOME" || return 1
  if [ "$_self" != "$PA_BIN" ]; then
    cp "$_self" "$PA_BIN.new" && mv -f "$PA_BIN.new" "$PA_BIN" || return 1
  fi
  chmod 755 "$PA_BIN"
}

pa_autostart_on() {
  case $PA_PLATFORM in
    merlin)
      # Merlin runs /jffs/scripts/services-start at boot, but only with custom
      # scripts enabled. It is a system setting, so say so rather than do it quietly.
      pa_nv jffs2_scripts
      if [ "$PA_V" != 1 ]; then
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
      command -v cru >/dev/null 2>&1 && cru d protection-agent 2>/dev/null
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
pa_setup() {
  _self=$1
  _code=$2
  _project=$3
  _key=$4
  [ "$PA_PLATFORM" = unknown ] && pa_die "this router is not running Asuswrt-Merlin or OpenWrt."
  [ -n "$PA_ROOT" ] || [ "$(id -u)" = 0 ] || pa_die "run this as the router's admin (root) user."
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

pa_uninstall() {
  pa_stop
  pa_autostart_off
  rm -f "$PA_CONF" "$PA_TMP".*
  case $PA_PLATFORM in
    merlin) rm -rf "$PA_HOME" ;;
    *) rm -f "$PA_BIN" ;;
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
    uninstall) pa_uninstall ;;
    version) pa_say "$PA_AGENT_VERSION" ;;
    *) pa_die "unknown command '$_cmd'. Use setup, start, stop, status, report or uninstall." ;;
  esac
}

[ "${PA_SOURCED:-0}" = 1 ] || pa_main "$@"
