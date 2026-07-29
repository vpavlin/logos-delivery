#!/usr/bin/env bash
# Stubbed for this environment: the cross/docker RLN build is unavailable. Uses a
# pre-staged arm64 librln.so at build/android/<abi>/librln.so (vendored from the
# existing mobile app). RLN FFI is stable, so the liblogosdelivery link is fine.
set -e
nwaku_build_dir=$1; abi=$5
output_dir="${nwaku_build_dir}/android/${abi}"
mkdir -p "${output_dir}"
if [ -f "${output_dir}/librln.so" ]; then
  echo "build_rln_android(stub): using pre-staged ${output_dir}/librln.so"
  exit 0
fi
echo "build_rln_android(stub): MISSING pre-staged librln.so at ${output_dir}"; exit 1
