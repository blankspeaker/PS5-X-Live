#!/bin/bash
# Builds the self-contained runtime bundled in the app: build/runtime/
# Apple silicon (arm64) only.
#   bin/ffmpeg        LGPL FFmpeg built from the official source tarball
#   bin/streamlink    launcher for the bundled Streamlink
#   python/           python-build-standalone CPython (trimmed)
#   site/             Streamlink + dependencies (from scripts/requirements-runtime.txt)
# Every download is checked against the SHA-256 below.
set -euo pipefail
shopt -s nullglob
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DL="$ROOT/build/downloads"; RT="$ROOT/build/runtime"
FFVER=8.1.3
FFSHA=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
FFURL="https://ffmpeg.org/releases/ffmpeg-$FFVER.tar.xz"
OSSLVER=3.5.9
OSSLSHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OSSLURL="https://github.com/openssl/openssl/releases/download/openssl-$OSSLVER/openssl-$OSSLVER.tar.gz"
PBS=20261026; PYVER=3.13.18
PBSURL="https://github.com/astral-sh/python-build-standalone/releases/download/$PBS"
PYSHA=e5af2fde6a937a0e0c795a0c595c4efb70578d57463a2657c819992b9b9acbac
PYFILE="cpython-$PYVER+$PBS-aarch64-apple-darwin-install_only.tar.gz"
[ "$(uname -m)" = arm64 ] || { echo "build on an Apple silicon Mac" >&2; exit 1; }
mkdir -p "$DL"

fetch() { # url file sha256
  [ -f "$DL/$2" ] || curl -fsSL -o "$DL/$2" "$1"
  echo "$3  $DL/$2" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $2" >&2; rm -f "$DL/$2"; exit 1; }
}

# --- FFmpeg (LGPL-2.1-or-later; no GPL or nonfree parts enabled) -------------
fetch "$FFURL" "ffmpeg-$FFVER.tar.xz" "$FFSHA"
fetch "$OSSLURL" "openssl-$OSSLVER.tar.gz" "$OSSLSHA"
FW=/private/tmp/ps5xlive-ffmpeg   # neutral path: it ends up in the binary's debug strings
build_openssl() {
  # Static OpenSSL (Apache-2.0), built in the neutral FW path so no user path leaks into ffmpeg.
  local sb="$FW/openssl-$OSSLVER"
  tar xf "$DL/openssl-$OSSLVER.tar.gz" -C "$FW"
  cd "$sb"
  ./Configure darwin64-arm64-cc no-shared no-tests no-docs no-legacy \
    --prefix=/usr/local --openssldir=/usr/local/ssl -mmacosx-version-min=13.0 > ossl-configure.log 2>&1
  make -j"$(sysctl -n hw.ncpu)" > ossl-make.log 2>&1
  make install_sw DESTDIR="$FW/ossl" > ossl-install.log 2>&1
  cd - >/dev/null
}
build_ffmpeg() {
  build_openssl
  local OSSL="$FW/ossl/usr/local"
  local b="$FW/b-arm64"
  mkdir -p "$b"; cd "$b"
  PKG_CONFIG_PATH="$OSSL/lib/pkgconfig" PKG_CONFIG_LIBDIR="$OSSL/lib/pkgconfig" \
  "$FW/ffmpeg-$FFVER/configure" --prefix=/usr/local \
    --arch=aarch64 --cc="clang -arch arm64" \
    --extra-cflags="-mmacosx-version-min=13.0 -I$OSSL/include" \
    --extra-ldflags="-arch arm64 -mmacosx-version-min=13.0 -L$OSSL/lib" \
    --pkg-config-flags=--static \
    --disable-autodetect --disable-everything --disable-doc --disable-debug --disable-ffplay --disable-ffprobe \
    --enable-openssl --enable-videotoolbox \
    --enable-protocol=pipe,file,tcp,udp,tls,rtmp,rtmps \
    --enable-demuxer=mpegts,flv,aac,mp3,h264 \
    --enable-muxer=flv,mpegts,null \
    --enable-parser=h264,aac,mpegaudio,opus,ac3 \
    --enable-decoder=h264,aac,aac_latm,mp3float,opus,ac3,wrapped_avframe,pcm_s16le,pcm_f32le,pcm_f64le \
    --enable-encoder=aac,h264_videotoolbox \
    --enable-bsf=aac_adtstoasc,h264_mp4toannexb,extract_extradata \
    --enable-indev=lavfi \
    --enable-filter=testsrc,sine,aresample,aformat,format,scale,null,anull,buffer,buffersink,abuffer,abuffersink \
    > configure.log 2>&1
  make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1
  cd - >/dev/null
}
if [ ! -x "$DL/ffmpeg-$FFVER-arm64" ] || [ "$DL/ffmpeg-$FFVER-arm64" -ot "$0" ]; then
  rm -rf "$FW"; mkdir -p "$FW"; tar xf "$DL/ffmpeg-$FFVER.tar.xz" -C "$FW"
  build_ffmpeg
  cp "$FW/b-arm64/ffmpeg" "$DL/ffmpeg-$FFVER-arm64"
  rm -rf "$FW"
fi

# --- Python + Streamlink --------------------------------------------------------
rm -rf "$RT"; mkdir -p "$RT/bin"
cp "$DL/ffmpeg-$FFVER-arm64" "$RT/bin/ffmpeg"
# --- MediaMTX (MIT) : robust RTMP server for "Direct from PS5 (LAN)" mode ------
MTXVER=v1.21.3
MTXSHA=bc1a0762fd18ffb413bcd81dcb9a072ac159fbd1f27e79ac6f14598aaac5ed3f
fetch "https://github.com/bluenviron/mediamtx/releases/download/$MTXVER/mediamtx_${MTXVER}_darwin_arm64.tar.gz" "mediamtx_${MTXVER}_darwin_arm64.tar.gz" "$MTXSHA"
tar xzf "$DL/mediamtx_${MTXVER}_darwin_arm64.tar.gz" -C "$DL" mediamtx
cp "$DL/mediamtx" "$RT/bin/mediamtx"; rm -f "$DL/mediamtx"

fetch "$PBSURL/${PYFILE//+/%2B}" "$PYFILE" "$PYSHA"
tar xzf "$DL/$PYFILE" -C "$RT"; P="$RT/python"
  rm -rf "$P"/include "$P"/share "$P"/lib/pkgconfig "$P"/lib/itcl* "$P"/lib/tcl* "$P"/lib/tk* "$P"/lib/thread* \
    "$P"/lib/libtcl* "$P"/lib/python3.13/{test,idlelib,tkinter,turtledemo,ensurepip,pydoc_data,__phello__,config-3.13-darwin} \
    "$P"/lib/python3.13/site-packages/* "$P"/lib/python3.13/lib-dynload/_tkinter*
  find "$P/bin" -mindepth 1 ! -name python3.13 ! -name python3 -exec rm -f {} +
  find "$P" -name __pycache__ -type d -prune -exec rm -rf {} +
# An untrimmed copy of the host-CPU Python runs pip and compileall.
rm -rf "$DL/hostpy"; mkdir -p "$DL/hostpy"
tar xzf "$DL/$PYFILE" -C "$DL/hostpy"
HOSTPY="$DL/hostpy/python/bin/python3"
"$HOSTPY" -E -s -m pip install -q --disable-pip-version-check --no-compile --target "$RT/site" \
  --platform macosx_11_0_universal2 --only-binary=:all: --python-version 3.13 --implementation cp \
  --require-hashes --no-deps -r "$ROOT/scripts/requirements-runtime.txt"
[ -d "$RT/site/streamlink" ] || { echo "pip install failed" >&2; exit 1; }
# pycountry ships translations Streamlink never uses; drop them (LGPL data, unmodified otherwise)
rm -rf "$RT/site/bin" "$RT/site/pycountry/locales" "$RT/site/lxml/includes"
find "$RT/site" \( -name "*.h" -o -name "*.pyx" -o -name "*.pxd" -o -name "*.c" \) -delete
find "$RT/site" -name __pycache__ -type d -prune -exec rm -rf {} +

cat > "$RT/streamlink_launch.py" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "site"))
from streamlink_cli.main import main
sys.exit(main())
PY
cat > "$RT/bin/streamlink" <<'SH'
#!/bin/bash
# Runs the bundled Streamlink with the bundled Python.
RT="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
exec "$RT/python/bin/python3" -E -s -B "$RT/streamlink_launch.py" "$@"
SH
chmod 755 "$RT/bin/streamlink" "$RT/bin/ffmpeg"
# Precompile bytecode once so startup is fast and the signed bundle is never written to.
"$HOSTPY" -E -s -m compileall -q -j 0 -s "$RT" -p runtime "$RT/site" "$RT/python/lib/python3.13" >/dev/null || true
"$RT/bin/streamlink" --version
"$RT/bin/ffmpeg" -hide_banner -protocols | grep -q rtmps
echo "runtime ready: $(du -sh "$RT" | cut -f1)"
