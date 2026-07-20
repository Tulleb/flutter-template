#!/bin/bash
# Restores ASSETCATALOG_* values overwritten by flutter_launcher_icons.
# That package matches any line containing "ASSETCATALOG" and sets it to AppIcon.

set -euo pipefail

PBXPROJ="ios/Runner.xcodeproj/project.pbxproj"

if [ ! -f "$PBXPROJ" ]; then
  echo "error: $PBXPROJ not found. Run from the project root." >&2
  exit 1
fi

perl -i -pe '
  s/ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME = AppIcon;/ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME = WidgetBackground;/;
  s/ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AppIcon;/ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;/;
  s/ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = AppIcon;/ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;/;
' "$PBXPROJ"

