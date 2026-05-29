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

DEVELOPER_ID_INSTALLER="Developer ID Installer: Rite Irrigation LLC (5UAM478N24)"

cd "${PROJECT_ROOT}"
export COPYFILE_DISABLE=1

/bin/rm -rf "${BUILD_DIR}"
/bin/mkdir -p "${EXPORT_PATH}" "${PKG_ROOT}/Applications"

xcodebuild archive \
	-project SiemensIPGiver.xcodeproj \
	-scheme SiemensIPGiver \
	-configuration Release \
	-destination "generic/platform=macOS" \
	-archivePath "${ARCHIVE_PATH}" \
	DEVELOPMENT_TEAM=5UAM478N24

xcodebuild -exportArchive \
	-archivePath "${ARCHIVE_PATH}" \
	-exportPath "${EXPORT_PATH}" \
	-exportOptionsPlist "${PROJECT_ROOT}/Distribution/ExportOptions/DeveloperIDExportOptions.plist"

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

if security find-identity -v | /usr/bin/grep -q "${DEVELOPER_ID_INSTALLER}"; then
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
