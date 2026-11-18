#!/usr/bin/env bash
# Publish installer builds to the private downloads bucket and promote one to
# the stable "latest" names. Uses only the aws CLI and coreutils.
#
#   publish.sh upload  <bucket> <prefix> <channel> <build-id> <dir>
#   publish.sh promote <bucket> <prefix> <channel> <build-id> <map-file>
#
# upload:  copies every regular file in <dir> (not subdirectories) to
#          s3://<bucket>/<prefix>/<channel>/builds/<build-id>/<file>, plus a
#          SHA256SUMS.txt. A build id is claimed first with a conditional
#          write, so it is used once, even by two uploads at the same time.
# promote: <map-file> has one "<stable-name><TAB><file-name-in-build>" per line
#          (blank lines and # comments are ignored). The whole map is checked
#          against the build before anything changes. Then each build file is
#          copied server-side onto <channel>/latest/<stable-name>, and
#          latest/SHA256SUMS.txt (stable names) and latest/VERSION.txt are
#          written. A lock object allows one promotion per channel at a time.
#
# <channel> is an opaque id chosen by the operator. Server-side copies above
# 5 GB are out of scope. Needs an aws CLI v2 whose `s3api put-object` has
# `--if-none-match` (S3 conditional writes).
set -euo pipefail

tmp=""         # the working dir of upload and promote, removed on exit
lock_bucket="" # the promotion lock this run holds, removed on exit
lock_key=""
cleanup() {
  [ -z "$tmp" ] || rm -rf "$tmp"
  [ -z "$lock_key" ] || aws s3api delete-object --bucket "$lock_bucket" --key "$lock_key" >/dev/null ||
    echo "publish.sh: could not remove the lock s3://$lock_bucket/$lock_key; remove it by hand" >&2
}
trap cleanup EXIT

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() {
  echo "publish.sh: $*" >&2
  exit 1
}

segment() { # segment <label> <value>: a plain key segment
  [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "$1 must be a plain name (letters, digits, . _ -): '$2'"
}

filename() { # filename <value>: a file name that is safe in a key and a header
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+@=-]*$ ]] || die "unsupported file name: '$1'"
  [ "$1" != "SHA256SUMS.txt" ] || die "SHA256SUMS.txt is written by this script"
}

stable_name() { # stable_name <value>: a name under latest/
  filename "$1"
  [ "$1" != "VERSION.txt" ] || die "VERSION.txt is written by this script"
}

claim() { # claim <bucket> <key>: create the object only if it does not exist
  local empty
  empty="$(mktemp "$tmp/claim.XXXXXX")"
  aws s3api put-object --bucket "$1" --key "$2" --body "$empty" --if-none-match '*' >/dev/null 2>"$tmp/claim.err" && return 0
  grep -q -E 'PreconditionFailed|ConditionalRequestConflict' "$tmp/claim.err" && return 1
  cat "$tmp/claim.err" >&2
  die "could not write s3://$1/$2"
}

content_type() {
  case "$1" in
    *.dmg) echo "application/x-apple-diskimage" ;;
    *.exe) echo "application/vnd.microsoft.portable-executable" ;;
    *) echo "application/octet-stream" ;;
  esac
}

size_of() { # size_of <s3-uri>
  local bucket key
  bucket="${1#s3://}"
  key="${bucket#*/}"
  bucket="${bucket%%/*}"
  aws s3api head-object --bucket "$bucket" --key "$key" --query ContentLength --output text
}

cmd_upload() {
  [ $# -eq 5 ] || usage
  local bucket="$1" prefix="$2" channel="$3" build="$4" dir="$5"
  segment bucket "$bucket"
  segment prefix "$prefix"
  segment channel "$channel"
  segment build-id "$build"
  [ -d "$dir" ] || die "not a directory: $dir"

  local dest="s3://$bucket/$prefix/$channel/builds/$build"
  local existing
  # shellcheck disable=SC2016 # the backticks are a JMESPath literal, not shell
  existing="$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix/$channel/builds/$build/" --max-keys 1 --query 'length(Contents || `[]`)' --output text)"
  [ "$existing" = "0" ] || die "build $build already exists under $dest/; choose a new build id"

  local files=() f
  while IFS= read -r -d '' f; do
    f="${f##*/}"
    filename "$f"
    files+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f -print0 | sort -z)
  [ ${#files[@]} -gt 0 ] || die "no files in $dir"

  tmp="$(mktemp -d)"
  (cd "$dir" && sha256sum -- "${files[@]}") >"$tmp/SHA256SUMS.txt"

  # The listing above is not atomic. This claim is: of two uploads with the
  # same build id, one fails here.
  claim "$bucket" "$prefix/$channel/builds/$build/.claim" ||
    die "build $build is already claimed under $dest/; choose a new build id"

  for f in "${files[@]}"; do
    echo "upload $f"
    aws s3 cp "$dir/$f" "$dest/$f" --only-show-errors
  done
  aws s3 cp "$tmp/SHA256SUMS.txt" "$dest/SHA256SUMS.txt" --content-type text/plain --only-show-errors
  echo "uploaded ${#files[@]} files to $dest/"
}

cmd_promote() {
  [ $# -eq 5 ] || usage
  local bucket="$1" prefix="$2" channel="$3" build="$4" map="$5"
  segment bucket "$bucket"
  segment prefix "$prefix"
  segment channel "$channel"
  segment build-id "$build"
  [ -f "$map" ] || die "not a file: $map"

  local src="s3://$bucket/$prefix/$channel/builds/$build"
  local dst="s3://$bucket/$prefix/$channel/latest"
  tmp="$(mktemp -d)"

  aws s3 cp "$src/SHA256SUMS.txt" "$tmp/build-sums.txt" --only-show-errors ||
    die "build $build has no SHA256SUMS.txt under $src/"

  # Pass 1: check the whole map and every source file. Nothing under latest/
  # changes unless all of it is valid.
  local stable name sum line i n=0 seen=$'\n'
  local stables=() names=() sums=() sizes=()
  while IFS=$'\t' read -r stable name || [ -n "$stable" ]; do
    case "$stable" in '' | '#'*) continue ;; esac
    [ -n "${name:-}" ] || die "map line needs <stable-name><TAB><file-in-build>: '$stable'"
    stable_name "$stable"
    filename "$name"
    [[ "$seen" != *$'\n'"$stable"$'\n'* ]] || die "the map names $stable twice"
    seen+="$stable"$'\n'

    sum=""
    while IFS= read -r line; do
      [ "${line#*  }" = "$name" ] && sum="${line%%  *}"
    done <"$tmp/build-sums.txt"
    [ -n "$sum" ] || die "$name is not in the build's SHA256SUMS.txt"

    stables+=("$stable")
    names+=("$name")
    sums+=("$sum")
    sizes+=("$(size_of "$src/$name")") || die "$name is not in the build under $src/"
    n=$((n + 1))
  done <"$map"
  [ "$n" -gt 0 ] || die "the map file has no entries"

  claim "$bucket" "$prefix/$channel/.promote-lock" ||
    die "another promotion holds s3://$bucket/$prefix/$channel/.promote-lock; if none is running, remove that object and retry"
  lock_bucket="$bucket"
  lock_key="$prefix/$channel/.promote-lock"

  # Pass 2: copy.
  local got
  : >"$tmp/latest-sums.txt"
  for ((i = 0; i < n; i++)); do
    stable="${stables[i]}"
    name="${names[i]}"
    echo "promote $name -> latest/$stable"
    aws s3 cp "$src/$name" "$dst/$stable" \
      --metadata-directive REPLACE \
      --content-disposition "attachment; filename=\"$name\"" \
      --content-type "$(content_type "$name")" \
      --cache-control no-store \
      --only-show-errors

    got="$(size_of "$dst/$stable")"
    [ "${sizes[i]}" = "$got" ] || die "size mismatch for $stable: source ${sizes[i]} bytes, copy $got bytes"
    printf '%s  %s\n' "${sums[i]}" "$stable" >>"$tmp/latest-sums.txt"
  done

  printf 'build: %s\npromoted: %s\n' "$build" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$tmp/VERSION.txt"
  aws s3 cp "$tmp/latest-sums.txt" "$dst/SHA256SUMS.txt" --content-type text/plain --cache-control no-store --only-show-errors
  aws s3 cp "$tmp/VERSION.txt" "$dst/VERSION.txt" --content-type text/plain --cache-control no-store --only-show-errors
  echo "promoted $n files from build $build to $dst/"
}

case "${1:-}" in
  upload)
    shift
    cmd_upload "$@"
    ;;
  promote)
    shift
    cmd_promote "$@"
    ;;
  *) usage ;;
esac
