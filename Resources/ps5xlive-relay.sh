#!/bin/bash
# PS5 X Live relay: Twitch (via streamlink) -> X (RTMPS), copy-only.
#
#   ps5xlive-relay.sh start|stop|status|run
#   ps5xlive-relay.sh normalize <channel name or URL>
#   ps5xlive-relay.sh selfcheck   (reports which ffmpeg/streamlink will be used)
#
# Settings come from the environment (the app sets these):
#   PS5XL_CHANNEL  Twitch channel name or URL (YouTube live URLs also work)
#   PS5XL_SERVER   RTMP(S) server URL, e.g. rtmps://<host>:443/x
#   PS5XL_KEY      stream key
# Optional:
#   PS5XL_HOME     state dir (default ~/Library/Application Support/PS5-X-Live)
#   PS5XL_LOG      log file  (default ~/Library/Logs/PS5-X-Live.log)
#   PS5XL_TEST_SOURCE=1  use a generated test pattern instead of streamlink
#   PS5XL_ONCE=1         exit after the first attempt (no retry)
#
# "Direct from PS5 (LAN)" mode (receive the PS5's own Twitch broadcast over the LAN):
#   PS5XL_MODE=lan       receive RTMP on :1935 instead of pulling Twitch
#   PS5XL_LAN_IP         this Mac's LAN IP (auto-detected if unset)
#   PS5XL_RTMP_PORT      RTMP listen port (default 1935)
#   PS5XL_DNS_PORT       DNS listen port (default 53)
#   PS5XL_NO_DNS=1       don't start the bundled DNS server (receiver only)
#   ps5xlive-relay.sh lanip   prints the detected LAN IP
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="${PS5XL_RUNTIME:-$HERE/runtime}"
# Bundled tools first, then Homebrew / system as a fallback.
export PATH="$RUNTIME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
STATE="${PS5XL_HOME:-$HOME/Library/Application Support/PS5-X-Live}"
LOG="${PS5XL_LOG:-$HOME/Library/Logs/PS5-X-Live.log}"
PIDFILE="$STATE/relay.pid"
PROGRESS="$STATE/progress"
TWITCH_FLAG="$STATE/twitch.on"      # present when "Also send to Twitch" simulcast is enabled
TWITCH_STATUS="$STATE/twitch_status"
TWITCH_HOST_DEFAULT="ingest.global-contribute.live-video.net"
OVERRIDE_FLAG="$STATE/override.on"   # present only while the LAN relay runs; DNS checks it per query
SELF="$HERE/$(basename "$0")"
DNSPY="$HERE/ps5xlive-dns.py"
MODE="${PS5XL_MODE:-twitch}"
RTMP_PORT="${PS5XL_RTMP_PORT:-1935}"
DNS_PORT="${PS5XL_DNS_PORT:-53}"
mkdir -p "$STATE" "$(dirname "$LOG")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S %Z') $*" >> "$LOG"; }
lanip() {
  local ip
  for i in en0 en1 en2 en3; do ip="$(ipconfig getifaddr "$i" 2>/dev/null)"; [ -n "$ip" ] && { echo "$ip"; return; }; done
  local def; def="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  [ -n "$def" ] && ipconfig getifaddr "$def" 2>/dev/null
}
alive() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
DNS_PIDFILE="$STATE/dns.pid"
DNSMON_PIDFILE="$STATE/dnsmon.pid"
dns_alive() { [ -f "$DNSMON_PIDFILE" ] && kill -0 "$(cat "$DNSMON_PIDFILE" 2>/dev/null)" 2>/dev/null; }
dns_start() {
  if dns_alive; then echo "dns running"; return 0; fi
  local LAN_IP="${PS5XL_LAN_IP:-$(lanip)}"
  nohup perl -e 'setpgrp(0,0); exec @ARGV' "$SELF" dnsmon "$LAN_IP" >/dev/null 2>&1 &
  sleep 0.5; dns_status
}
dns_stop() {
  if dns_alive; then
    local pg; pg=$(cat "$DNSMON_PIDFILE")
    kill -TERM -"$pg" 2>/dev/null
    for i in 1 2 3 4 5 6; do kill -0 "$pg" 2>/dev/null || break; sleep 0.3; done
    kill -KILL -"$pg" 2>/dev/null
    log "DNS stopped"
  fi
  rm -f "$DNSMON_PIDFILE" "$DNS_PIDFILE"; echo "dns idle"
}
dns_status() { if dns_alive; then echo "dns running"; else echo "dns idle"; fi; }

normalize() {
  local s="${1//[[:space:]]/}"
  case "$s" in
    *youtube.com/*|*youtu.be/*) [[ "$s" == http* ]] || s="https://$s"; echo "$s"; return ;;
  esac
  s="${s#http://}"; s="${s#https://}"; s="${s#www.}"; s="${s#m.}"; s="${s#twitch.tv/}"
  s="${s#@}"; s="${s%%/*}"; s="${s%%\?*}"
  [[ "$s" =~ ^[A-Za-z0-9_]{1,25}$ ]] || { echo "invalid channel" >&2; return 1; }
  echo "https://www.twitch.tv/$(echo "$s" | tr 'A-Z' 'a-z')"
}

status() {
  if ! alive; then echo idle; return; fi
  if [ -f "$PROGRESS" ] && [ $(( $(date +%s) - $(stat -f %m "$PROGRESS") )) -le 6 ] \
     && [ "$(grep '^frame=' "$PROGRESS" | tail -1 | cut -d= -f2)" -gt 0 ] 2>/dev/null; then
    echo relaying
  else
    echo waiting
  fi
}

selfcheck() {
  # Downloaded copies carry the quarantine flag on every nested file; the app itself was already approved.
  [ -d "$RUNTIME" ] && xattr -dr com.apple.quarantine "$RUNTIME" 2>/dev/null
  local ok=0 p v src
  p="$(command -v ffmpeg || true)"
  if [ -n "$p" ] && "$p" -hide_banner -protocols 2>/dev/null | grep -qx '  rtmps'; then
    v="$("$p" -version 2>/dev/null | head -1 | awk '{print $3}')"
    src=$([[ "$p" == "$RUNTIME"/* ]] && echo bundled || echo "$p")
    echo "ffmpeg ok $v $src"
  else echo "ffmpeg missing"; ok=1; fi
  p="$(command -v streamlink || true)"
  if [ -n "$p" ] && v="$("$p" --version 2>/dev/null)"; then
    src=$([[ "$p" == "$RUNTIME"/* ]] && echo bundled || echo "$p")
    echo "streamlink ok ${v#streamlink } $src"
  else echo "streamlink missing"; ok=1; fi
  return $ok
}

mask() {
  # Hide the X stream key and the PS5's Twitch stream key (live_<...>) from logs.
  if [ -n "$PS5XL_KEY" ]; then
    sed -u -E -e "s|$PS5XL_KEY|***|g" -e 's/live_[A-Za-z0-9._-]+/live_***/g'
  else
    sed -u -E 's/live_[A-Za-z0-9._-]+/live_***/g'
  fi
}

source_cmd() {
  if [ "${PS5XL_TEST_SOURCE:-0}" = 1 ]; then
    ffmpeg -hide_banner -nostdin -loglevel error -re -f lavfi -i "testsrc=size=1280x720:rate=30" \
      -f lavfi -i "sine=frequency=440:sample_rate=48000" -t "${PS5XL_TEST_SECONDS:-15}" \
      -vf format=nv12 -c:v h264_videotoolbox -realtime 1 -b:v 2500k -g 60 -c:a aac -b:a 128k -f mpegts -
  else
    streamlink --twitch-low-latency --hls-live-edge 1 --stream-segment-threads 2 \
      --twitch-supported-codecs h264 --retry-streams 5 --retry-max 0 --stream-timeout 20 \
      -l warning "$CHANNEL_URL" best -O
  fi
}

write_mediamtx_conf() {
  cat > "$1" <<'YML'
logLevel: info
logDestinations: [stdout]
api: no
metrics: no
pprof: no
playback: no
rtsp: no
hls: no
webrtc: no
srt: no
moq: no
rtmp: yes
rtmpEncryption: "no"
pathDefaults:
  # When the PS5 starts publishing, pull it back out locally and push copy-only to X.
  # When the PS5 starts publishing, hand off to the fork supervisor, which pushes
  # copy-only to X and (if "Also send to Twitch" is enabled) also to Twitch, independently.
  runOnAvailable: $PS5XL_SELF fork $MTX_PATH $MTX_QUERY
  runOnAvailableRestart: yes
paths:
  all_others:
YML
  sed -i '' "s/^rtmp: yes/rtmpAddress: :${RTMP_PORT}\nrtmp: yes/" "$1"
}

run() {
  echo $$ > "$PIDFILE"
  trap 'log "stopping"; rm -f "$PIDFILE" "$PROGRESS" "$OVERRIDE_FLAG"; trap - TERM INT; kill -TERM -$$ 2>/dev/null; exit 0' TERM INT
  SERVER="${PS5XL_SERVER%/}"
  if [ "$MODE" != lan ] && [ "${PS5XL_TEST_SOURCE:-0}" != 1 ]; then
    CHANNEL_URL="$(normalize "$PS5XL_CHANNEL")" || { log "invalid channel"; rm -f "$PIDFILE"; exit 1; }
  fi
  if [ -z "$SERVER" ] || [ -z "$PS5XL_KEY" ]; then log "missing server URL or stream key"; rm -f "$PIDFILE"; exit 1; fi
  for t in ffmpeg streamlink; do command -v $t >/dev/null || { log "missing $t (brew install streamlink ffmpeg)"; rm -f "$PIDFILE"; exit 1; }; done
  log "using $(command -v ffmpeg) and $(command -v streamlink)"
  AUDIO=(-c:a copy)
  backoff=2
  if [ "$MODE" = lan ]; then
    LAN_IP="${PS5XL_LAN_IP:-$(lanip)}"
    # DNS runs independently (dns-start/dns-stop). The relay only toggles the override flag:
    # while the relay runs, DNS redirects Twitch ingest here; when stopped, DNS passes through to Twitch.
    : > "$OVERRIDE_FLAG"
    log "LAN mode: redirecting Twitch ingest to $LAN_IP (overrides ON), receiving RTMP on :$RTMP_PORT, forwarding to $SERVER"
  else
    log "relay started (pgid $$) source=${CHANNEL_URL:-test pattern} server=$SERVER"
  fi
  while true; do
    rm -f "$PROGRESS"
    start=$(date +%s)
    if [ "$MODE" = lan ]; then
      log "waiting for PS5 broadcast on :$RTMP_PORT (MediaMTX)"
      MEDIAMTX="$RUNTIME/bin/mediamtx"
      CONF="$STATE/mediamtx.yml"
      write_mediamtx_conf "$CONF"
      PS5XL_SELF="$SELF" PS5XL_TARGET="$SERVER/$PS5XL_KEY" PS5XL_PROGRESS="$PROGRESS" \
      PS5XL_RTMP_PORT="$RTMP_PORT" PS5XL_HOME="$STATE" PS5XL_LOG="$LOG" PS5XL_KEY="$PS5XL_KEY" \
      PS5XL_TWITCH_FLAG="$TWITCH_FLAG" PS5XL_TWITCH_HOST="${PS5XL_TWITCH_HOST:-$TWITCH_HOST_DEFAULT}" \
      PS5XL_LAN_IP="$LAN_IP" \
        "$MEDIAMTX" "$CONF" 2>&1 | mask | tee -a "$LOG" > "$STATE/last_ffmpeg.txt"
    else
      log "waiting for source"
      source_cmd 2> >(mask >> "$LOG") \
      | ffmpeg -hide_banner -nostdin -loglevel warning -nostats -progress "$PROGRESS" -stats_period 2 \
        -fflags nobuffer -i pipe:0 -map 0:v:0 -map 0:a:0? -c:v copy "${AUDIO[@]}" \
        -f flv -flvflags no_duration_filesize "$SERVER/$PS5XL_KEY" 2>&1 \
      | mask | tee -a "$LOG" > "$STATE/last_ffmpeg.txt"
    fi
    frames="$(grep '^frame=' "$PROGRESS" 2>/dev/null | tail -1 | cut -d= -f2)"
    log "pipe ended (frames pushed: ${frames:-0})"
    if [ "${AUDIO[1]}" = copy ] && grep -qiE "codec not currently supported|Could not write header|not supported in container" "$STATE/last_ffmpeg.txt"; then
      log "audio copy rejected; switching to AAC transcode"; AUDIO=(-c:a aac -b:a 160k -ar 48000)
    fi
    [ "${PS5XL_ONCE:-0}" = 1 ] && { rm -f "$PIDFILE" "$PROGRESS"; log "relay finished"; exit 0; }
    if [ $(( $(date +%s) - start )) -gt 30 ]; then backoff=2; fi
    log "retrying in ${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff < 15 ? backoff * 2 : 15 ))
  done
}

case "$1" in
  run) run ;;
  dnsmon)
    echo $$ > "$DNSMON_PIDFILE"
    trap 'rm -f "$DNSMON_PIDFILE" "$DNS_PIDFILE"; trap - TERM INT; kill -TERM -$$ 2>/dev/null; exit 0' TERM INT
    LAN_IP="${2:-${PS5XL_LAN_IP:-$(lanip)}}"
    DNS_PY="$RUNTIME/python/bin/python3"; [ -x "$DNS_PY" ] || DNS_PY="$(command -v python3)"
    [ -n "$DNS_PY" ] || { log "WARN: python3 not found; DNS not started"; rm -f "$DNSMON_PIDFILE"; exit 1; }
    log "DNS monitor started (pgid $$) using $DNS_PY lan-ip=$LAN_IP port=$DNS_PORT"
    while true; do
      "$DNS_PY" -B "$DNSPY" --lan-ip "$LAN_IP" --port "$DNS_PORT" --override-flag "$OVERRIDE_FLAG" > >(mask >> "$LOG") 2>&1 &
      dpid=$!; echo "$dpid" > "$DNS_PIDFILE"; wait "$dpid"; rc=$?
      log "DNS server exited (rc=$rc); restarting in 2s"
      sleep 2
    done ;;
  dns-start) dns_start ;;
  dns-stop) dns_stop ;;
  dns-status) dns_status ;;
  start)
    if alive; then echo "already running"; exit 0; fi
    nohup perl -e 'setpgrp(0,0); exec @ARGV' "$SELF" run >/dev/null 2>&1 &
    sleep 0.5; status ;;
  stop)
    if alive; then
      pg=$(cat "$PIDFILE"); kill -TERM -"$pg" 2>/dev/null
      for i in 1 2 3 4 5 6; do kill -0 "$pg" 2>/dev/null || break; sleep 0.5; done
      kill -KILL -"$pg" 2>/dev/null
      log "relay stopped"
    fi
    rm -f "$PIDFILE" "$PROGRESS" "$OVERRIDE_FLAG" "$TWITCH_STATUS"; echo idle ;;
  status) status ;;
  fork)
    # Supervisor launched by MediaMTX runOnAvailable. Pushes copy-only to X always,
    # and to Twitch too while the simulcast flag is present. The two pushers are
    # independent process groups: either can fail/restart without affecting the other.
    MTX_PATH="$2"; MTX_QUERY="$3"
    xpg=""; twpg=""
    fork_cleanup() {
      [ -n "$xpg" ] && kill -TERM -"$xpg" 2>/dev/null
      [ -n "$twpg" ] && kill -TERM -"$twpg" 2>/dev/null
      rm -f "$TWITCH_STATUS"
      trap - TERM INT EXIT
      exit 0
    }
    trap fork_cleanup TERM INT EXIT
    perl -e 'setpgrp(0,0); exec @ARGV' "$SELF" pushx "$MTX_PATH" &
    xpg=$!
    log "fork: X pusher started (pgid $xpg)"
    while kill -0 "$xpg" 2>/dev/null; do
      if [ -f "$TWITCH_FLAG" ]; then
        if [ -z "$twpg" ] || ! kill -0 "$twpg" 2>/dev/null; then
          perl -e 'setpgrp(0,0); exec @ARGV' "$SELF" pushtwitch "$MTX_PATH" "$MTX_QUERY" &
          twpg=$!
          log "fork: Twitch simulcast pusher started (pgid $twpg)"
        fi
      else
        if [ -n "$twpg" ] && kill -0 "$twpg" 2>/dev/null; then
          kill -TERM -"$twpg" 2>/dev/null; twpg=""; rm -f "$TWITCH_STATUS"
          log "fork: Twitch simulcast stopped (toggle off)"
        fi
      fi
      sleep 2
    done
    fork_cleanup ;;
  pushx)
    # Independent copy-only push to X with its own retry/backoff.
    MTX_PATH="$2"
    SRC="rtmp://127.0.0.1:${PS5XL_RTMP_PORT:-1935}/$MTX_PATH"
    backoff=2
    while true; do
      start=$(date +%s)
      ffmpeg -hide_banner -nostdin -loglevel error -nostats \
        -progress "${PS5XL_PROGRESS:-$PROGRESS}" -stats_period 2 -rw_timeout 15000000 \
        -i "$SRC" -map 0:v:0 -map 0:a:0? -c copy \
        -f flv -flvflags no_duration_filesize "$PS5XL_TARGET"
      log "X push ended"
      [ $(( $(date +%s) - start )) -gt 30 ] && backoff=2
      sleep "$backoff"; backoff=$(( backoff < 15 ? backoff * 2 : 15 ))
    done ;;
  pushtwitch)
    # Independent copy-only simulcast to the real Twitch ingest, using the key the PS5
    # published with ($MTX_PATH already carries /app/<key>). RTMPS (443) first, plain RTMP
    # (1935) as a fallback. Keeps the broadcaster's query params if present. Own retry/backoff.
    MTX_PATH="$2"; MTX_QUERY="$3"
    SRC="rtmp://127.0.0.1:${PS5XL_RTMP_PORT:-1935}/$MTX_PATH"
    HOST="${PS5XL_TWITCH_HOST:-$TWITCH_HOST_DEFAULT}"
    SP="${PS5XL_TWITCH_RTMPS_PORT:-443}"; PP="${PS5XL_TWITCH_RTMP_PORT:-1935}"
    LAN_IP="${PS5XL_LAN_IP:-$(lanip)}"
    Q=""; [ -n "$MTX_QUERY" ] && Q="?$MTX_QUERY"
    backoff=2
    echo starting > "$TWITCH_STATUS"
    while true; do
      # Resolve the ingest host via the Mac's own (upstream) resolver and refuse to loop
      # back to the LAN relay. If HOST is already an IP literal, use it as-is.
      if [[ "$HOST" =~ ^[0-9.]+$ ]]; then ips="$HOST"; else ips="$(dig +short "$HOST" A 2>/dev/null | grep -E '^[0-9]+\.')"; fi
      if [ -z "$ips" ]; then
        echo error > "$TWITCH_STATUS"; log "Twitch: could not resolve ingest host; retrying in ${backoff}s"
        sleep "$backoff"; backoff=$(( backoff < 15 ? backoff * 2 : 15 )); continue
      fi
      if echo "$ips" | grep -qx "$LAN_IP"; then
        echo error > "$TWITCH_STATUS"; log "Twitch: ingest resolves to this Mac (loop); refusing; retrying in 10s"
        sleep 10; continue
      fi
      start=$(date +%s); echo sending > "$TWITCH_STATUS"
      for URL in "rtmps://$HOST:$SP/$MTX_PATH$Q" "rtmp://$HOST:$PP/$MTX_PATH$Q"; do
        ffmpeg -hide_banner -nostdin -loglevel error -nostats -rw_timeout 15000000 \
          -i "$SRC" -map 0:v:0 -map 0:a:0? -c copy \
          -f flv -flvflags no_duration_filesize "$URL" && break
        log "Twitch: ${URL%%:*} push ended/failed"
      done
      echo error > "$TWITCH_STATUS"
      [ $(( $(date +%s) - start )) -gt 30 ] && backoff=2
      sleep "$backoff"; backoff=$(( backoff < 15 ? backoff * 2 : 15 ))
    done ;;
  twitch-on) : > "$TWITCH_FLAG"; echo on ;;
  twitch-off) rm -f "$TWITCH_FLAG" "$TWITCH_STATUS"; echo off ;;
  twitch-status)
    if [ ! -f "$TWITCH_FLAG" ]; then echo off
    elif [ -f "$TWITCH_STATUS" ]; then cat "$TWITCH_STATUS"
    else echo starting; fi ;;
  normalize) normalize "$2" ;;
  selfcheck) selfcheck ;;
  lanip) lanip ;;
  *) echo "usage: $(basename "$0") start|stop|status|dns-start|dns-stop|dns-status|twitch-on|twitch-off|twitch-status|selfcheck|lanip|normalize <channel>"; exit 2 ;;
esac
