# SilenceTrimmer media binaries

Static **FFmpeg** builds that [SilenceTrimmer](https://silencetrimmer.com) vendors,
together with the script that produces them.

This repository exists so that the binaries the application ships, and the exact
recipe that built them, are publicly available to anyone who receives a copy of
the application.

## Why these are built rather than downloaded

SilenceTrimmer needs `libx264`, `libx265` and **`libzimg`** — the last because its
HDR-to-SDR conversion is built on `zscale`, and a build without it fails at graph
construction rather than at runtime.

For macOS on Apple Silicon there is no prebuilt that can be redistributed: the
widely used builds are configured `--enable-nonfree`, which forbids redistribution
outright, and the alternatives are either Intel-only, licensed for education only,
or do not target macOS at all. So these are compiled from source.

## What is here

Each release contains, per architecture, a gzipped `ffmpeg` and `ffprobe`, the
`configure` line each was built with, and a build record. They are static, link
only against `/usr/lib` and `/System`, and are **not** `--enable-nonfree`.

`scripts/build-ffmpeg-macos.sh` is what produces them.

## Licence

The binaries are **GPL-3.0-or-later** (`--enable-gpl --enable-version3`). The full
text is in [`COPYING.GPLv3`](COPYING.GPLv3).

Corresponding source for each release is the FFmpeg tag named in that release,
from `https://git.ffmpeg.org/ffmpeg.git`, together with the pinned versions of
x264, x265 and zimg recorded there and the build script in this repository.

The build deliberately uses `--disable-network --disable-autodetect`: the
application opens local files only, and dropping the protocol layer removes
attack surface from a binary that parses untrusted input.
