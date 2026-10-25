#!/usr/bin/env bash
# Fallback for a stalling `container image pull`: fetch one platform of a Docker Hub image
# blob by blob with resumable curl, lay it out as an OCI image layout and tar it for
# `container image load`.
#
# Usage: fetch.sh <repo> <tag> <platform-arch> <out-dir>
#   e.g. fetch.sh espressif/idf v5.5.4 arm64 /path/to/out
set -euo pipefail

REPO="$1"; TAG="$2"; ARCH="$3"; OUT="$4"
REG=https://registry-1.docker.io
mkdir -p "$OUT/blobs/sha256"

token() {
  curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO}:pull" | jq -r .token
}

ACCEPT_INDEX='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'
ACCEPT_MANIFEST='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

TOKEN=$(token)
INDEX=$(curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT_INDEX" "$REG/v2/$REPO/manifests/$TAG")
DESC=$(jq -c --arg a "$ARCH" '.manifests[] | select(.platform.os=="linux" and .platform.architecture==$a)' <<<"$INDEX" | head -1)
[ -n "$DESC" ] || { echo "no linux/$ARCH manifest" >&2; exit 1; }
MDIGEST=$(jq -r .digest <<<"$DESC")
MTYPE=$(jq -r .mediaType <<<"$DESC")
MSIZE=$(jq -r .size <<<"$DESC")

MANIFEST_FILE="$OUT/blobs/sha256/${MDIGEST#sha256:}"
curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: $ACCEPT_MANIFEST" "$REG/v2/$REPO/manifests/$MDIGEST" -o "$MANIFEST_FILE"
echo "manifest $MDIGEST ($MTYPE)"

fetch_blob() {
  local digest="$1" size="$2" file="$OUT/blobs/sha256/${1#sha256:}"
  local have=0
  [ -f "$file" ] && have=$(stat -f %z "$file")
  if [ "$have" = "$size" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "${digest#sha256:}" ]; then
    echo "have $digest"; return
  fi
  local attempt=0
  until [ "$(stat -f %z "$file" 2>/dev/null || echo 0)" = "$size" ]; do
    attempt=$((attempt + 1))
    [ $attempt -le 50 ] || { echo "giving up on $digest" >&2; exit 1; }
    # token lifetime is short; take a fresh one per attempt. --speed-limit/--speed-time
    # turn a stalled connection into an error so the loop resumes it with -C -.
    curl -fsSL -C - --speed-limit 20000 --speed-time 60 --connect-timeout 20 \
      -H "Authorization: Bearer $(token)" "$REG/v2/$REPO/blobs/$digest" -o "$file" || true
    echo "  $digest: $(stat -f %z "$file" 2>/dev/null || echo 0)/$size (attempt $attempt)"
  done
  [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "${digest#sha256:}" ] || { echo "digest mismatch $digest" >&2; exit 1; }
  echo "ok $digest"
}

fetch_blob "$(jq -r .config.digest "$MANIFEST_FILE")" "$(jq -r .config.size "$MANIFEST_FILE")"
jq -r '.layers[] | "\(.digest) \(.size)"' "$MANIFEST_FILE" | while read -r d s; do fetch_blob "$d" "$s"; done

NAME="docker.io/$REPO:$TAG"
echo '{"imageLayoutVersion":"1.0.0"}' > "$OUT/oci-layout"
jq -n --arg d "$MDIGEST" --arg t "$MTYPE" --argjson s "$MSIZE" --arg n "$NAME" --arg tag "$TAG" --arg a "$ARCH" '{
  schemaVersion: 2,
  mediaType: "application/vnd.oci.image.index.v1+json",
  manifests: [{
    mediaType: $t, digest: $d, size: $s,
    platform: {os: "linux", architecture: $a},
    annotations: {
      "org.opencontainers.image.ref.name": $tag,
      "io.containerd.image.name": $n,
      "com.apple.containerization.image.name": $n
    }
  }]
}' > "$OUT/index.json"
echo "layout ready in $OUT"
