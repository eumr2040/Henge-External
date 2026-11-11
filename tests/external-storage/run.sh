#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output=$(mktemp -d)
fixture_pid=
trap 'if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; fi; rm -rf "$output"' EXIT
swiftc -swift-version 5 -D HENGE_STORAGE_PROBE \
  ios/Henge/FullDiskWriter.swift ios/Henge/RestoreImageDownload.swift \
  ios/Henge/InstallSpace.swift ios/Henge/ExternalFolderValidation.swift ios/Henge/ExternalDisk.swift \
  tests/external-storage/main.swift -o "$output/storage-tests"
"$output/storage-tests"
swiftc -swift-version 5 ios/Henge/RestoreImageDownload.swift \
  tests/external-storage/DownloadTests.swift -o "$output/download-tests"
python3 tests/external-storage/http_fixture.py "$output/port" &
fixture_pid=$!
attempt=0
while [ ! -s "$output/port" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -gt 100 ]; then echo 'HTTP fixture did not start'; exit 1; fi
  sleep 0.1
done
"$output/download-tests" "http://127.0.0.1:$(cat "$output/port")/"
