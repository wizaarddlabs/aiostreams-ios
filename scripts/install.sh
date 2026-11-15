#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 1 || ( "${1:-}" != info && "${1:-}" != install ) ]]; then
  echo 'Usage: scripts/install.sh info | install' >&2
  exit 1
fi
if [[ "$1" = info ]]; then
  xcrun devicectl list devices
  if ! security find-certificate -c 'Apple Development' -p 2>/dev/null |
    openssl x509 -noout -subject -nameopt sep_multiline 2>/dev/null |
    sed -n 's/^[[:space:]]*OU[[:space:]]*=[[:space:]]*/DEVELOPMENT_TEAM=/p'; then
    echo 'Could not read an Apple Development certificate. Find your team in Xcode Signing & Capabilities.' >&2
  fi
  if [[ -n "${DEVICE:-}" ]]; then
    xcrun devicectl device info apps --device "$DEVICE" --search AIOStreams
  fi
  exit 0
fi

: "${PLATFORM:?Set PLATFORM to ios or tvos}"
: "${DEVICE:?Set DEVICE to the device UDID}"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple team ID}"
: "${BUNDLE_ID:?Set BUNDLE_ID to your app bundle ID}"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo 'Invalid BUNDLE_ID.' >&2; exit 1; }
case "$PLATFORM" in
  ios) scheme=AIOStreams; sdk=iphoneos; original=io.github.aiostreams-ios.app ;;
  tvos) scheme=AIOStreamsTV; sdk=appletvos; original=io.github.aiostreams-ios.tv ;;
  *) echo 'PLATFORM must be ios or tvos.' >&2; exit 1 ;;
esac

version="${APP_VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)}"
version="${version#v}"
if [[ -z "${BUILD_NUMBER:-}" && "$(git rev-parse --is-shallow-repository)" = true ]]; then
  echo 'Shallow clone: fetch full history or set BUILD_NUMBER.' >&2
  exit 1
fi
number="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
for value in "$version" "$number"; do
  [[ "$value" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo 'Invalid version: fetch release tags or set APP_VERSION and BUILD_NUMBER.' >&2; exit 1; }
done

if [[ "$PLATFORM" = ios && ! -f AIOStreams/Resources/web/index.html ]]; then
  scripts/build-web.sh
fi
xcodegen generate
sed -i '' "s/PRODUCT_BUNDLE_IDENTIFIER = \"$original/PRODUCT_BUNDLE_IDENTIFIER = \"$BUNDLE_ID/g" \
  AIOStreams.xcodeproj/project.pbxproj
# Free accounts cannot sign App Groups; Top Shelf recommendations are disabled.
xcodebuild build -project AIOStreams.xcodeproj -scheme "$scheme" \
  -configuration Release -destination "id=$DEVICE" -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_ENTITLEMENTS= \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$number"
xcrun devicectl device install app --device "$DEVICE" \
  "build/DerivedData/Build/Products/Release-$sdk/$scheme.app"
