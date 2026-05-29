#!/bin/sh
set -eu

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_DIR="${PROJECT_ROOT}/build/ReleaseDistribution"
ARCHIVE_PATH="${BUILD_DIR}/SiemensIPGiver.xcarchive"
EXPORT_PATH="${BUILD_DIR}/Export"
PKG_ROOT="${BUILD_DIR}/PackageRoot"
COMPONENT_PKG="${BUILD_DIR}/SiemensIPGiver-component.pkg"
FINAL_PKG="${BUILD_DIR}/SiemensIPGiver.pkg"
SIGNED_PKG="${BUILD_DIR}/SiemensIPGiver-signed.pkg"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DEVELOPMENT_TEAM_ID="${DEVELOPMENT_TEAM_ID:-}"
DEVELOPER_ID_INSTALLER="${DEVELOPER_ID_INSTALLER:-}"

if [ -z "${DEVELOPMENT_TEAM_ID}" ]; then
	echo "error: DEVELOPMENT_TEAM_ID is required for a Developer ID release build."
	echo "example: DEVELOPMENT_TEAM_ID=ABCDE12345 NOTARY_PROFILE=ProfileName Distribution/build-release.sh"
	exit 1
fi

if [ -z "${DEVELOPER_ID_INSTALLER}" ]; then
	DEVELOPER_ID_INSTALLER=$(security find-identity -v | /usr/bin/sed -n 's/.*"\(Developer ID Installer:.*\)"/\1/p' | /usr/bin/head -n 1)
fi

cd "${PROJECT_ROOT}"
export COPYFILE_DISABLE=1

/bin/rm -rf "${BUILD_DIR}"
/bin/mkdir -p "${EXPORT_PATH}" "${PKG_ROOT}/Applications"

EXPORT_OPTIONS_PLIST="${BUILD_DIR}/DeveloperIDExportOptions.plist"
/bin/cat > "${EXPORT_OPTIONS_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>export</string>
	<key>method</key>
	<string>developer-id</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>stripSwiftSymbols</key>
	<true/>
	<key>teamID</key>
	<string>${DEVELOPMENT_TEAM_ID}</string>
</dict>
</plist>
EOF

xcodebuild archive \
	-project SiemensIPGiver.xcodeproj \
	-scheme SiemensIPGiver \
	-configuration Release \
	-destination "generic/platform=macOS" \
	-archivePath "${ARCHIVE_PATH}" \
	DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM_ID}"

xcodebuild -exportArchive \
	-archivePath "${ARCHIVE_PATH}" \
	-exportPath "${EXPORT_PATH}" \
	-exportOptionsPlist "${EXPORT_OPTIONS_PLIST}"

/bin/cp -R "${EXPORT_PATH}/SiemensIPGiver.app" "${PKG_ROOT}/Applications/"
/bin/cp -R "${PROJECT_ROOT}/Distribution/PackageRoot/Library" "${PKG_ROOT}/"
/usr/bin/find "${PKG_ROOT}" -name '._*' -delete
/usr/bin/xattr -cr "${PKG_ROOT}"

pkgbuild \
	--root "${PKG_ROOT}" \
	--scripts "${PROJECT_ROOT}/Distribution/PackageScripts" \
	--identifier com.gmaendel.SiemensIPGiver \
	--version 1.0 \
	--install-location / \
	"${COMPONENT_PKG}"

if [ -n "${DEVELOPER_ID_INSTALLER}" ] && security find-identity -v | /usr/bin/grep -q "${DEVELOPER_ID_INSTALLER}"; then
	productbuild \
		--package "${COMPONENT_PKG}" \
		--sign "${DEVELOPER_ID_INSTALLER}" \
		"${SIGNED_PKG}"
	PKG_TO_DISTRIBUTE="${SIGNED_PKG}"
else
	/bin/cp "${COMPONENT_PKG}" "${FINAL_PKG}"
	PKG_TO_DISTRIBUTE="${FINAL_PKG}"
	echo "warning: Developer ID Installer certificate was not found. Built an unsigned package at ${FINAL_PKG}."
fi

if [ -n "${NOTARY_PROFILE}" ]; then
	xcrun notarytool submit "${PKG_TO_DISTRIBUTE}" --keychain-profile "${NOTARY_PROFILE}" --wait
	xcrun stapler staple "${PKG_TO_DISTRIBUTE}"
else
	echo "warning: NOTARY_PROFILE is not set. Skipping notarization."
fi

echo "Release package: ${PKG_TO_DISTRIBUTE}"
