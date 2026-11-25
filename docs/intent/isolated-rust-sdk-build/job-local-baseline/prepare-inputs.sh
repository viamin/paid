#!/bin/sh
# Run only inside the existing isolated job, under an owned fresh workspace.
# This assembles the pinned public input identities used by the successful baseline.
set -eu
: "${WORK_ROOT:?Set WORK_ROOT to the assigned physical /workspace job directory; never use the host root}"
fail() {
  printf '%s\n' "$1" >&2
  exit 1
}
test "$WORK_ROOT" = /workspace || fail "WORK_ROOT must be the assigned /workspace job directory"
if test ! -d "$WORK_ROOT" || test -L "$WORK_ROOT"; then
  fail "WORK_ROOT must be a physical directory"
fi
work_root_physical=$(CDPATH='' cd -P "$WORK_ROOT" && pwd)
test "$work_root_physical" = "$WORK_ROOT" || fail "WORK_ROOT must not contain symbolic links"
for reserved_path in downloads ruby tools tools/protoc toolchain-inputs toolchain unpack cargo target source.before.sha; do
  if test -e "$WORK_ROOT/$reserved_path" || test -L "$WORK_ROOT/$reserved_path"; then
    fail "refusing occupied reserved path: $WORK_ROOT/$reserved_path"
  fi
done
preparation_lock="$WORK_ROOT/.prepare-inputs.lock"
if ! mkdir "$preparation_lock"; then
  fail "preparation is already in progress or was not cleaned up: $preparation_lock"
fi
cleanup_preparation_lock() {
  rmdir "$preparation_lock"
}
trap cleanup_preparation_lock EXIT
trap 'exit 1' HUP INT TERM
mkdir "$WORK_ROOT/downloads" "$WORK_ROOT/ruby" "$WORK_ROOT/tools" "$WORK_ROOT/toolchain-inputs"
mkdir "$WORK_ROOT/tools/protoc"
fetch_checked() {
  curl --fail --location --connect-timeout 10 --max-time 120 --silent --show-error "$1" -o "$2"
  printf '%s  %s\n' "$3" "$2" | sha256sum -c -
}
base=https://static.rust-lang.org/dist/2026-04-16
fetch_checked "$base/rustc-1.95.0-aarch64-unknown-linux-gnu.tar.xz" "$WORK_ROOT/toolchain-inputs/rustc.tar.xz" 0fe3689eeaed603e5ef24572d11597d3edadaefd2cb181674ad621260f2501d2
fetch_checked "$base/rust-std-1.95.0-aarch64-unknown-linux-gnu.tar.xz" "$WORK_ROOT/toolchain-inputs/rust-std.tar.xz" 3a21b271b1ff973b94d69b25e7a39992f9fbcae1ab6d9475844a23e6ad3908ac
fetch_checked "$base/cargo-1.95.0-aarch64-unknown-linux-gnu.tar.xz" "$WORK_ROOT/toolchain-inputs/cargo.tar.xz" 7c070aeba9bbf12073646995a03f36c346bb5f541d0078ba6d9dc2a7adaaf6af
fetch_checked https://github.com/protocolbuffers/protobuf/releases/download/v34.0/protoc-34.0-linux-aarch_64.zip "$WORK_ROOT/downloads/protoc.zip" f0b8aad28be5ea6150c082f96ac57e028154afb9ee29f4ce092b5a39df8ae6c8
unzip -q "$WORK_ROOT/downloads/protoc.zip" -d "$WORK_ROOT/tools/protoc"
chmod u+x "$WORK_ROOT/tools/protoc/bin/protoc"
git init --bare "$WORK_ROOT/downloads/ruby.git"
git --git-dir="$WORK_ROOT/downloads/ruby.git" fetch --depth=1 https://github.com/temporalio/sdk-ruby.git 61db6dd4b75e3b15731e58f26934b33c17663237
test "$(git --git-dir="$WORK_ROOT/downloads/ruby.git" rev-parse FETCH_HEAD)" = 61db6dd4b75e3b15731e58f26934b33c17663237
git --git-dir="$WORK_ROOT/downloads/ruby.git" archive 61db6dd4b75e3b15731e58f26934b33c17663237 > "$WORK_ROOT/downloads/ruby.tar"
tar --no-same-owner -xf "$WORK_ROOT/downloads/ruby.tar" -C "$WORK_ROOT/ruby"
git init --bare "$WORK_ROOT/downloads/core.git"
git --git-dir="$WORK_ROOT/downloads/core.git" fetch --depth=1 https://github.com/temporalio/sdk-rust.git c675c32469af707e1c979a7b808c70b4a0608b82
test "$(git --git-dir="$WORK_ROOT/downloads/core.git" rev-parse FETCH_HEAD)" = c675c32469af707e1c979a7b808c70b4a0608b82
test "$(git --git-dir="$WORK_ROOT/downloads/ruby.git" rev-parse 61db6dd4b75e3b15731e58f26934b33c17663237:temporalio/ext/sdk-core)" = c675c32469af707e1c979a7b808c70b4a0608b82
mkdir -p "$WORK_ROOT/ruby/temporalio/ext/sdk-core"
git --git-dir="$WORK_ROOT/downloads/core.git" archive c675c32469af707e1c979a7b808c70b4a0608b82 > "$WORK_ROOT/downloads/core.tar"
tar --no-same-owner -xf "$WORK_ROOT/downloads/core.tar" -C "$WORK_ROOT/ruby/temporalio/ext/sdk-core"
printf '47aba453a6f46d71b5deba2d09e1e6b9ef036cc5ba7263562793205e142bc9aa  %s\n' "$WORK_ROOT/ruby/temporalio/Cargo.lock" | sha256sum -c -
