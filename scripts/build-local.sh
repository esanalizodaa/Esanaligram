#!/bin/bash
# MacBook'ta yerel derleme. Gerekli: versions.json'daki Xcode sürümü (26.6), config/local.env içinde DEEPINFRA_API_KEY.
set -euo pipefail
cd "$(dirname "$0")/.."
source UPSTREAM
if [ ! -d telegram-ios ]; then
  git clone --recursive --depth 1 --branch "$tag" "$repo" telegram-ios
  python3 scripts/apply.py telegram-ios
fi
cd telegram-ios
python3 build-system/Make/Make.py --cacheDir="$HOME/telegram-bazel-cache" build \
  --configurationPath=../config/esnaligram-configuration.json \
  --codesigningInformationPath=build-system/fake-codesigning \
  --buildNumber=${BUILD_NUMBER:-1} --configuration=release_arm64
find bazel-bin/Telegram -name "*.ipa" -exec cp {} ../Esnaligram.ipa \;
echo "IPA: $(cd ..; pwd)/Esnaligram.ipa"
