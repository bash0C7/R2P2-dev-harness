#!/usr/bin/env bash
# Ruby <version> を tmp/container/ruby/<version> に build する (常駐コンテナの中で。rake container:ruby)。
# base image の Ruby は 3.2 で、upstream picoruby の CI は 4.0.1。Gemfile の typeprof 0.32 は >= 3.3 を要るので、
# `rake test:gems:steep` は 3.2 では bundle install で落ちる。置き場所は mount された harness の中なので、
# コンテナを作り直しても残り、Mac には何も入らない。
set -euo pipefail
VERSION="${1:?usage: ruby.sh <version>}"
HARNESS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="$HARNESS_ROOT/tmp/container/ruby/$VERSION"
if [ -x "$PREFIX/bin/ruby" ]; then echo "$PREFIX/bin/ruby is already there"; exit 0; fi

SRC="$HARNESS_ROOT/tmp/container/ruby-src"
TARBALL="$SRC/ruby-$VERSION.tar.gz"
mkdir -p "$SRC"
# 取得物の検証は ruby-lang.org の index.txt の SHA256 で行う (列は name url sha1 sha256 sha512)
SHA256=$(curl -fsSL https://cache.ruby-lang.org/pub/ruby/index.txt |
  awk -v n="ruby-$VERSION" '$1 == n && $2 ~ /\.tar\.gz$/ { print $4 }')
[ -n "$SHA256" ] || { echo "ruby-$VERSION is not in cache.ruby-lang.org/pub/ruby/index.txt" >&2; exit 1; }
[ -f "$TARBALL" ] || curl -fsSL "https://cache.ruby-lang.org/pub/ruby/${VERSION%.*}/ruby-$VERSION.tar.gz" -o "$TARBALL"
echo "$SHA256  $TARBALL" | sha256sum -c -

rm -rf "$SRC/ruby-$VERSION"
tar -xzf "$TARBALL" -C "$SRC"
cd "$SRC/ruby-$VERSION"
./configure --prefix="$PREFIX" --disable-install-doc
make -j"$(nproc)"
make install
cd /
rm -rf "$SRC"
"$PREFIX/bin/ruby" -v
