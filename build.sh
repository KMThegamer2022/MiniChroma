#!/bin/zsh
set -eu
cd "${0:A:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
build_directory=$(mktemp -d /tmp/minichroma-build.XXXXXX)
output_directory="${MINICHROMA_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$output_directory"
xcodebuild -project MiniChroma.xcodeproj -scheme MiniChromaApp -configuration Release -derivedDataPath "$build_directory" ALWAYS_SEARCH_USER_PATHS=NO build
codesign --verify --deep --strict "$build_directory/Build/Products/Release/MiniChroma.app"
ditto --norsrc -c -k --keepParent "$build_directory/Build/Products/Release/MiniChroma.app" "$output_directory/MiniChroma.zip"
ditto --norsrc "$build_directory/Build/Products/Release/MiniChroma.app" "$output_directory/MiniChroma.app"
# Documents can add Finder metadata on copy; remove only metadata on this generated app.
xattr -d com.apple.FinderInfo "$output_directory/MiniChroma.app" 2>/dev/null || true
print "Built $output_directory/MiniChroma.app and verified signed $output_directory/MiniChroma.zip"
