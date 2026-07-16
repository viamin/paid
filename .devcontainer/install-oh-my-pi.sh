#!/bin/bash

# Install Oh My Pi (omp) and its Bun runtime into the devcontainer user's home.

set -euo pipefail

BUN_VERSION="${BUN_VERSION:-1.3.14}"
BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-$HOME/.local/bin}"
OMP_PACKAGE="${OMP_PACKAGE:-@oh-my-pi/pi-coding-agent@17.0.1}"
BUN_RELEASE_BASE_URL="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}"

export BUN_INSTALL
export PATH="${BUN_INSTALL}/bin:${PATH}"

install_bun() {
  local arch
  local asset
  local checksum
  local tmpdir

  command -v unzip >/dev/null 2>&1 || {
    echo "ERROR: unzip is required to install Bun." >&2
    exit 1
  }

  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64)
      asset="bun-linux-x64.zip"
      if ! grep -qm1 avx2 /proc/cpuinfo; then
        asset="bun-linux-x64-baseline.zip"
      fi
      ;;
    arm64)
      asset="bun-linux-aarch64.zip"
      ;;
    *)
      echo "ERROR: Unsupported architecture for Bun: $arch" >&2
      exit 1
      ;;
  esac

  tmpdir="$(mktemp -d)"

  curl -fsSL "${BUN_RELEASE_BASE_URL}/SHASUMS256.txt" -o "${tmpdir}/SHASUMS256.txt"
  checksum="$(awk -v asset="$asset" '$2 == asset { print $1 }' "${tmpdir}/SHASUMS256.txt")"
  if [ -z "$checksum" ]; then
    echo "ERROR: No Bun checksum found for ${asset}." >&2
    exit 1
  fi

  curl -fsSL "${BUN_RELEASE_BASE_URL}/${asset}" -o "${tmpdir}/${asset}"
  echo "${checksum}  ${tmpdir}/${asset}" | sha256sum -c -

  mkdir -p "${BUN_INSTALL}/bin"
  unzip -oq "${tmpdir}/${asset}" -d "${tmpdir}"
  install -m 0755 "${tmpdir}/${asset%.zip}/bun" "${BUN_INSTALL}/bin/bun"
  ln -sf "${BUN_INSTALL}/bin/bun" "${BUN_INSTALL}/bin/bunx"
  rm -rf "$tmpdir"
}

if ! command -v bun >/dev/null 2>&1 || [ "$(bun --version)" != "$BUN_VERSION" ]; then
  install_bun
fi

bun install -g "${OMP_PACKAGE}"
mkdir -p "${LOCAL_BIN_DIR}"
ln -sf "${BUN_INSTALL}/bin/bun" "${LOCAL_BIN_DIR}/bun"
ln -sf "${BUN_INSTALL}/bin/bunx" "${LOCAL_BIN_DIR}/bunx"
ln -sf "${BUN_INSTALL}/bin/omp" "${LOCAL_BIN_DIR}/omp"

omp --version
