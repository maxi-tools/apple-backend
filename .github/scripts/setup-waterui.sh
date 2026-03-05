#!/usr/bin/env bash
set -euo pipefail

repo_root="${GITHUB_WORKSPACE:-$(pwd)}"
waterui_dir="${repo_root}/waterui"

if [[ -n "${WATERUI_REF:-}" ]]; then
  waterui_ref="${WATERUI_REF}"
elif [[ "${GITHUB_BASE_REF:-}" == "main" || "${GITHUB_REF_NAME:-}" == "main" ]]; then
  waterui_ref="main"
else
  # Default all non-main flows (feature branches and dev PRs) to waterui/dev.
  waterui_ref="dev"
fi

echo "Using waterui ref: ${waterui_ref}"
rm -rf "${waterui_dir}"
git clone --depth 1 --branch "${waterui_ref}" https://github.com/water-rs/waterui.git "${waterui_dir}"

header_src="${waterui_dir}/ffi/waterui.h"
header_dst_dir="${repo_root}/Sources/CWaterUI/include"
header_dst="${header_dst_dir}/waterui.h"

if [[ ! -f "${header_src}" ]]; then
  echo "::error::Missing header: ${header_src}"
  exit 1
fi

mkdir -p "${header_dst_dir}"
cp "${header_src}" "${header_dst}"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "WATERUI_DIR=${waterui_dir}"
    echo "WATERUI_REF=${waterui_ref}"
  } >> "${GITHUB_ENV}"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "waterui_dir=${waterui_dir}"
    echo "waterui_ref=${waterui_ref}"
  } >> "${GITHUB_OUTPUT}"
fi
