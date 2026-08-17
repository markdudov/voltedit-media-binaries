#!/usr/bin/env bash
#
# Static ffmpeg + ffprobe for ONE macOS architecture.
#
#   ./scripts/build-ffmpeg-macos.sh <arm64|x86_64> <n7.1.5> <out-dir>
#
# Why we build this ourselves rather than pinning a prebuilt: the darwin-arm64
# ffmpeg we shipped until 2026 was an `--enable-nonfree` build, which may not be
# redistributed at all, and this app is sold. There is no acceptable prebuilt to
# swap in — evermeet is nonfree, osxexperts is "educational purposes only", BtbN
# publishes Linux and Windows only, and ffmpeg-static's newest darwin-arm64
# asset is a stale 6.0. Compiling is the only honest fix. The same build also
# ends the Rosetta dependency (the vendored arm64 ffprobe was an x86_64 binary)
# and the version skew between the two Mac architectures.
#
# Three external libraries and no more:
#   - libx264 / libx265, the software encode targets electron/media-format.ts
#     names by hand;
#   - libzimg, because TONEMAP_CHAIN in electron/filtergraph.ts is
#     `zscale=…,tonemap=hable,…zscale=…`. Without zimg there is no zscale and
#     EVERY HDR-to-SDR export fails at graph construction. This is the
#     requirement most easily missed and the most expensive to miss.
# Everything else the app spawns — prores_ks, aac, pcm_s16le, and the
# videotoolbox encoders — is internal to ffmpeg. mjpeg is deliberately NOT in
# that list: it was measured to be unused and removed from the capability gate.
#
# `--enable-nonfree` is deliberately absent and must stay absent.
#
# Build-host hygiene, deliberate:
#   --disable-autodetect      stops the host's Homebrew tree from linking itself
#                             in behind our back; every wanted feature is named.
#   PKG_CONFIG_LIBDIR         replaces (not extends) pkg-config's search path,
#                             so only the deps we just built can be found.
#   --disable-network         we open local files only. Dropping the protocol
#                             layer removes attack surface from a binary whose
#                             job is parsing hostile input.
#
# Prerequisites (macOS): Xcode command line tools, plus
#   brew install nasm automake cmake pkgconf libtool
# nasm is required for x86_64 assembly in x264/x265/ffmpeg; automake+libtool for
# zimg, which ships no configure script.
set -euo pipefail

# ---------------------------------------------------------------- pins -------
# A moving branch is not a pin. x264 publishes no release tags, so its "stable"
# branch is pinned by commit; everything else has a tag.
X264_COMMIT="${X264_COMMIT:-b35605ace3ddf7c1a5d67a2eb553f034aef41d55}"  # stable, 2025-06-04
# 4.2, not 4.1: 4.1's CMakeLists asks for `cmake_policy(SET CMP0025 OLD)` and
# `CMP0054 OLD`, and CMake 4 refuses to set either — the build cannot be
# configured at all on a current toolchain, with or without
# CMAKE_POLICY_VERSION_MINIMUM. Upstream fixed exactly that in 4.2 (the policy
# lines are gone and the minimum is written as a `2.8.8...3.10` range), so this
# is a version bump rather than a patch we would have to carry.
X265_TAG="${X265_TAG:-4.2}"
ZIMG_TAG="${ZIMG_TAG:-release-3.0.5}"

X264_REPO="${X264_REPO:-https://code.videolan.org/videolan/x264.git}"
X265_REPO="${X265_REPO:-https://bitbucket.org/multicoreware/x265_git.git}"
ZIMG_REPO="${ZIMG_REPO:-https://github.com/sekrit-twc/zimg.git}"
FFMPEG_REPO="${FFMPEG_REPO:-https://git.ffmpeg.org/ffmpeg.git}"

# --------------------------------------------------------------- usage -------
if [ $# -ne 3 ]; then
  echo "usage: $0 <arm64|x86_64> <ffmpeg-tag, e.g. n7.1.5> <out-dir>" >&2
  exit 2
fi

ARCH="$1"; FFMPEG_TAG="$2"; OUT="$3"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "unknown architecture: $ARCH (expected arm64 or x86_64)" >&2; exit 2 ;;
esac
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# Reusable work tree, so a failed ffmpeg configure does not cost another x265
# build. Set FFBUILD_WORK to keep the sources between runs; CI leaves it unset
# and gets a fresh temporary directory, which is what "clean build" means.
WORK="${FFBUILD_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/ffbuild.XXXXXX")}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
SRC="$WORK/src"                 # checkouts are architecture-independent
PREFIX="$WORK/deps-$ARCH"       # …their build products are not
BUILD="$WORK/build-$ARCH"
mkdir -p "$SRC" "$PREFIX" "$BUILD"

JOBS="$(sysctl -n hw.ncpu)"
HOST_ARCH="$(uname -m)"

# --------------------------------------------------------- environment -------
# Electron 43's floor. Anything built against a newer minimum would refuse to
# launch on a supported macOS.
export MACOSX_DEPLOYMENT_TARGET=11.0

# Inherited search paths are the other way a build host leaks into a binary;
# --disable-autodetect cannot see them.
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH LD_LIBRARY_PATH || true
unset CPPFLAGS || true

ARCHFLAG="-arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CFLAGS="$ARCHFLAG -I$PREFIX/include -O3 -fPIC"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="$ARCHFLAG -L$PREFIX/lib"
# Autotools projects get the architecture through the compiler itself: passing
# it only in CFLAGS loses it on the link lines some of them assemble by hand.
export CC="clang $ARCHFLAG"
export CXX="clang++ $ARCHFLAG"
# LIBDIR, not PATH: this REPLACES pkg-config's default search list, so
# /opt/homebrew/lib/pkgconfig cannot answer a query for x264.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

# Only when the target differs from the machine. Native builds must not take the
# cross path — autotools' --host suppresses run-time feature tests it can
# otherwise answer honestly.
CROSS=0
[ "$ARCH" = "$HOST_ARCH" ] || CROSS=1
case "$ARCH" in
  arm64)  TRIPLE="aarch64-apple-darwin" ;;   # config.sub's spelling, not Apple's
  x86_64) TRIPLE="x86_64-apple-darwin" ;;
esac
HOST_ARGS=()
[ "$CROSS" = 1 ] && HOST_ARGS=(--host="$TRIPLE")
# macOS still ships bash 3.2, where `"${arr[@]}"` on an EMPTY array is an
# unbound-variable error under `set -u`. Every optional argument list below is
# therefore expanded as `${arr[@]+"${arr[@]}"}`. Do not "simplify" those.

# autoreconf looks for `libtoolize`; Homebrew installs GNU libtool's as
# `glibtoolize` so as not to shadow Apple's /usr/bin/libtool. A shim is less
# fragile than hoping the caller exported LIBTOOLIZE.
if ! command -v libtoolize >/dev/null 2>&1 && command -v glibtoolize >/dev/null 2>&1; then
  mkdir -p "$WORK/shim"
  ln -sf "$(command -v glibtoolize)" "$WORK/shim/libtoolize"
  export PATH="$WORK/shim:$PATH"
fi

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing build tool: $1 — brew install nasm automake cmake pkgconf libtool" >&2
    exit 1
  }
}
for tool in git cmake nasm autoreconf automake aclocal libtoolize pkg-config clang; do require "$tool"; done

say() { printf '\n=== %s\n' "$*" >&2; }

# Clone at a pin, and prove the tree is still at it afterwards.
#
# A work tree reused from an earlier run that is NOT at the pinned revision
# makes the pin a lie — the surest way to ship a binary nobody can reproduce.
# Anything that is not exactly the pinned commit is thrown away and re-cloned;
# a few minutes of network is cheaper than reasoning about a stale checkout.
# The shallow tag clone is tried first and a plain clone is the fallback, which
# is also how a bare commit SHA (x264 publishes no tags) gets checked out.
fetch() { # fetch <dir> <repo> <ref> [extra clone args…]
  local dir="$1" repo="$2" ref="$3"; shift 3
  if [ -d "$dir/.git" ]; then
    local head want
    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)"
    want="$(git -C "$dir" rev-parse -q --verify "$ref^{commit}" 2>/dev/null || echo other)"
    if [ "$head" = "$want" ]; then say "$(basename "$dir"): reusing the checkout at $ref"; return; fi
    say "$(basename "$dir"): checkout is not at $ref — discarding it"
    rm -rf "$dir"
  fi
  say "$(basename "$dir"): cloning $repo @ $ref"
  git clone "$@" --branch "$ref" --depth 1 "$repo" "$dir" 2>/dev/null || {
    rm -rf "$dir"
    git clone "$@" "$repo" "$dir"
    git -C "$dir" checkout --detach "$ref"
    git -C "$dir" submodule update --init --recursive
  }
}

# ----------------------------------------------------------------- x264 ------
build_x264() {
  [ -f "$PREFIX/lib/libx264.a" ] && { say "x264: already installed"; return; }
  fetch "$SRC/x264" "$X264_REPO" "$X264_COMMIT"
  rm -rf "$BUILD/x264"; mkdir -p "$BUILD/x264"
  say "x264: configure ($ARCH)"
  # Built out of tree: x264's configure is happy with it and it keeps the two
  # architectures from sharing object files.
  ( cd "$BUILD/x264" && "$SRC/x264/configure" \
      --prefix="$PREFIX" --enable-static --enable-pic \
      --disable-cli --disable-opencl --disable-lavf --disable-swscale --disable-ffms \
      ${HOST_ARGS[@]+"${HOST_ARGS[@]}"} )
  make -C "$BUILD/x264" -j"$JOBS"
  make -C "$BUILD/x264" install
}

# ----------------------------------------------------------------- x265 ------
# Three builds, not one. A default x265 is 8-bit only, and ffmpeg would then
# refuse every 10- and 12-bit source — which would silently downgrade exports
# and break the "encode fidelity" invariant in CLAUDE.md. The 10- and 12-bit
# libraries are built with their C API hidden and linked into the 8-bit one,
# then all three archives are merged with Apple's libtool. This is what the
# prebuilt we are replacing did, and what distributions do.
build_x265() {
  [ -f "$PREFIX/lib/libx265.a" ] && { say "x265: already installed"; return; }
  fetch "$SRC/x265" "$X265_REPO" "$X265_TAG"

  local common=(
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
    -DCMAKE_SYSTEM_PROCESSOR="$ARCH"
    # x265 4.1 still declares cmake_minimum_required(VERSION 2.8.8); CMake 4
    # refuses that outright. This is the documented escape hatch, not a hack
    # around a real incompatibility — the project builds clean once it is past
    # the policy check.
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DENABLE_SHARED=OFF
    -DENABLE_CLI=OFF
  )
  # CMake takes the architecture from CMAKE_OSX_ARCHITECTURES. Leaving our
  # `clang -arch …` in CC as well makes it try to compile with the flag glued to
  # the compiler name, which fails its very first probe.
  local -a cm=(env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS cmake)

  say "x265: 12-bit ($ARCH)"
  "${cm[@]}" -S "$SRC/x265/source" -B "$BUILD/x265-12" "${common[@]}" \
    -DHIGH_BIT_DEPTH=ON -DMAIN12=ON -DEXPORT_C_API=OFF
  "${cm[@]}" --build "$BUILD/x265-12" -j "$JOBS"

  say "x265: 10-bit ($ARCH)"
  "${cm[@]}" -S "$SRC/x265/source" -B "$BUILD/x265-10" "${common[@]}" \
    -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
  "${cm[@]}" --build "$BUILD/x265-10" -j "$JOBS"

  say "x265: 8-bit + link ($ARCH)"
  "${cm[@]}" -S "$SRC/x265/source" -B "$BUILD/x265-8" "${common[@]}" \
    -DEXTRA_LIB="$BUILD/x265-10/libx265.a;$BUILD/x265-12/libx265.a" \
    -DEXTRA_LINK_FLAGS="-L$BUILD/x265-10;-L$BUILD/x265-12" \
    -DLINKED_10BIT=ON -DLINKED_12BIT=ON
  "${cm[@]}" --build "$BUILD/x265-8" -j "$JOBS"
  "${cm[@]}" --install "$BUILD/x265-8"

  # …and then replace what was just installed with the merged archive. Apple's
  # libtool, explicitly: `libtool` may be GNU libtool on a machine with
  # Homebrew's in PATH, and that one cannot merge static libraries.
  /usr/bin/libtool -static -o "$PREFIX/lib/libx265.a" \
    "$BUILD/x265-8/libx265.a" "$BUILD/x265-10/libx265.a" "$BUILD/x265-12/libx265.a" 2>/dev/null
}

# ----------------------------------------------------------------- zimg ------
build_zimg() {
  [ -f "$PREFIX/lib/libzimg.a" ] && { say "zimg: already installed"; return; }
  fetch "$SRC/zimg" "$ZIMG_REPO" "$ZIMG_TAG" --recursive
  # zimg publishes no dist tarball, so there is no configure until autotools
  # makes one. This is why automake/libtool are prerequisites.
  [ -f "$SRC/zimg/configure" ] || ( cd "$SRC/zimg" && ./autogen.sh )
  rm -rf "$BUILD/zimg"; mkdir -p "$BUILD/zimg"
  say "zimg: configure ($ARCH)"
  ( cd "$BUILD/zimg" && "$SRC/zimg/configure" \
      --prefix="$PREFIX" --enable-static --disable-shared --with-pic \
      ${HOST_ARGS[@]+"${HOST_ARGS[@]}"} )
  make -C "$BUILD/zimg" -j"$JOBS"
  make -C "$BUILD/zimg" install
}

# --------------------------------------------------------------- ffmpeg ------
build_ffmpeg() {
  fetch "$SRC/ffmpeg-$FFMPEG_TAG" "$FFMPEG_REPO" "$FFMPEG_TAG"
  rm -rf "$BUILD/ffmpeg"; mkdir -p "$BUILD/ffmpeg"

  local cross=()
  if [ "$CROSS" = 1 ]; then
    cross=(--enable-cross-compile --arch="$ARCH" --target-os=darwin
           --cc="clang $ARCHFLAG" --cxx="clang++ $ARCHFLAG")
  fi

  say "ffmpeg: configure $FFMPEG_TAG ($ARCH)"
  # No --enable-lzma, and it is not an oversight: the macOS SDK ships no
  # lzma.h (verified — zlib.h, bzlib.h and iconv.h are all there, lzma.h is
  # not), so `--enable-lzma` fails configure outright with "lzma requested but
  # not found". The only thing it buys ffmpeg is decoding LZMA-compressed TIFF,
  # which this app never opens; vendoring xz to get it back would be a whole
  # extra dependency for a format we do not read.
  #
  # --extra-libs is not padding either. -lc++ because x265 and zimg are C++
  # static libraries. -liconv because of a real hole in ffmpeg's configure that
  # only opens in exactly this combination: --disable-autodetect turns on its
  # internal `libc_iconv` (configure:4471, "we still want to probe for the
  # iconv from the libc"), and the check at configure:7428 then takes the
  # libc_iconv branch — which tries iconv WITHOUT a library and never reaches
  # the `elif enabled iconv` branch that would retry with -liconv. On macOS
  # that probe fails (the SDK's iconv.h declares a plain iconv_open, and
  # libSystem does not export one), yet --enable-iconv keeps CONFIG_ICONV=1, so
  # nothing complains until the final link dies on undefined _iconv_open from
  # mpegts.o. Naming the library here is the entire fix, and
  # /usr/lib/libiconv.2.dylib is a system library, so the otool check still
  # passes. Dropping --enable-iconv instead would silently lose subtitle
  # charset conversion.
  # --disable-autodetect turns off everything not named here, INCLUDING
  # threading: without --enable-pthreads this produces a single-threaded ffmpeg
  # that encodes several times slower and gives no hint of why. The verify step
  # below checks the built binary for it.
  ( cd "$BUILD/ffmpeg" && "$SRC/ffmpeg-$FFMPEG_TAG/configure" \
      --prefix="$OUT" \
      ${cross[@]+"${cross[@]}"} \
      --enable-gpl --enable-version3 \
      --enable-static --disable-shared \
      --enable-pthreads \
      --enable-libx264 --enable-libx265 --enable-libzimg \
      --enable-videotoolbox --enable-audiotoolbox \
      --enable-zlib --enable-bzlib --enable-iconv \
      --disable-network --disable-autodetect \
      --disable-doc --disable-ffplay --disable-debug \
      --pkg-config-flags=--static \
      --extra-cflags="$CFLAGS" \
      --extra-ldflags="$LDFLAGS" \
      --extra-libs="-lc++ -liconv" )

  # Proof, not a restatement of the flag: -buildconf only ever echoes what was
  # asked for, so it cannot tell a working --enable-pthreads from one configure
  # quietly declined. config.h is what the code was compiled against.
  # config.h lands in the build root; ffbuild/ next to it holds config.mak and
  # config.log, not this.
  grep -q '^#define HAVE_PTHREADS 1' "$BUILD/ffmpeg/config.h" \
    && grep -q '^#define HAVE_THREADS 1' "$BUILD/ffmpeg/config.h" || {
    echo "configure produced a build with no pthreads — every encode would be single-threaded" >&2
    exit 1
  }

  make -C "$BUILD/ffmpeg" -j"$JOBS"
  make -C "$BUILD/ffmpeg" install
}

# --------------------------------------------------------------- verify ------
# The build is not finished until these pass. They are the same four checks the
# task acceptance names, run here so a bad binary never leaves the machine that
# made it.
verify() {
  local fail=0 bin conf runnable=1
  local runner=()
  if [ "$CROSS" = 1 ]; then
    if [ "$HOST_ARCH" = arm64 ] && [ "$ARCH" = x86_64 ] && /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
      runner=(/usr/bin/arch -x86_64)   # Rosetta 2 is present; run the checks anyway
    else
      runnable=0
      say "verify: cannot run a $ARCH binary on $HOST_ARCH — checking the file, not the behaviour"
    fi
  fi

  for bin in "$OUT/bin/ffmpeg" "$OUT/bin/ffprobe"; do
    say "verify: $bin"
    [ -x "$bin" ] || { echo "MISSING: $bin"; fail=1; continue; }

    file "$bin"
    file "$bin" | grep -q "executable ${ARCH}$" || { echo "FAIL: not a $ARCH executable"; fail=1; }

    # The check that catches a build which quietly linked Homebrew: a dylib
    # under /opt/homebrew or /usr/local works here and dies on every customer's
    # machine.
    otool -L "$bin"
    if otool -L "$bin" | tail -n +2 | grep -vE '^[[:space:]]+(/usr/lib/|/System/)' | grep -q .; then
      echo "FAIL: $bin links something outside /usr/lib and /System"; fail=1
    fi

    if [ "$runnable" = 1 ]; then
      conf="$OUT/buildconf-$(basename "$bin").txt"
      ${runner[@]+"${runner[@]}"} "$bin" -hide_banner -version | head -1
      ${runner[@]+"${runner[@]}"} "$bin" -hide_banner -buildconf > "$conf"
      if grep -q -- '--enable-nonfree' "$conf"; then
        echo "FAIL: $bin is an --enable-nonfree build and may not be redistributed"; fail=1
      fi
      grep -q -- '--enable-libzimg' "$conf" \
        || { echo "FAIL: no libzimg — every HDR export would fail at graph construction"; fail=1; }
      grep -q -- '--enable-pthreads' "$conf" \
        || { echo "FAIL: no pthreads — --disable-autodetect swallowed threading"; fail=1; }
    fi
  done

  [ "$fail" = 0 ] || { echo; echo "VERIFICATION FAILED"; exit 1; }
  say "verify: all checks passed for $ARCH"
}

# ---------------------------------------------------------- provenance -------
# What the manifest's version/source/licence fields will have to say, written
# down by the thing that actually knows it, and shipped beside the binaries.
provenance() {
  cp "$SRC/ffmpeg-$FFMPEG_TAG/COPYING.GPLv3" "$OUT/COPYING.GPLv3"
  {
    echo "ffmpeg        $FFMPEG_TAG        $FFMPEG_REPO"
    echo "x264          $X264_COMMIT  $X264_REPO"
    echo "x265          $X265_TAG          $X265_REPO"
    echo "zimg          $ZIMG_TAG  $ZIMG_REPO"
    echo "arch          $ARCH"
    echo "deployment    macOS $MACOSX_DEPLOYMENT_TARGET"
    echo "built on      $(sw_vers -productName) $(sw_vers -productVersion), $(clang --version | head -1)"
    echo "licence       GPL-3.0-or-later (--enable-gpl --enable-version3, never --enable-nonfree)"
  } > "$OUT/BUILD-INFO.txt"
  cat "$OUT/BUILD-INFO.txt" >&2
}

say "work dir: $WORK   →   out: $OUT"
build_x264
build_x265
build_zimg
build_ffmpeg
provenance
verify
