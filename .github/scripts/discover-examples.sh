#!/usr/bin/env bash
set -euo pipefail

waterui_dir="${1:-${WATERUI_DIR:-${GITHUB_WORKSPACE:-$(pwd)}/waterui}}"
examples_root="${waterui_dir}/examples"

if [[ ! -d "${examples_root}" ]]; then
  echo "::error::Missing examples directory: ${examples_root}"
  exit 1
fi

examples=()
while IFS= read -r example; do
  examples+=("${example}")
done < <(
  find "${examples_root}" -mindepth 1 -maxdepth 1 -type d -print0 |
    while IFS= read -r -d '' example_dir; do
      if [[ -f "${example_dir}/Cargo.toml" ]]; then
        basename "${example_dir}"
      fi
    done |
    sort
)

if (( ${#examples[@]} == 0 )); then
  echo "::error::No runnable examples found under ${examples_root}"
  exit 1
fi

printf '%s\n' "${examples[@]}"
