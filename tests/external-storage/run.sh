#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
swiftc -swift-version 5 -D HENGE_STORAGE_PROBE \
  ios/Henge/FullDiskWriter.swift ios/Henge/ExternalDisk.swift \
  tests/external-storage/main.swift -o "$output/storage-tests"
"$output/storage-tests"
