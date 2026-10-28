#!/usr/bin/env bash

# Exit immediately on any error
set -e

# ANSI color codes
GREEN="\033[1;32m"
LIGHT_BLUE="\033[1;34m"
RED="\033[1;31m"
NC="\033[0m"  # No Color

# Log functions with colors
success() {
  echo -e "\n${GREEN}[RELEASE] $1${NC}"
}
info() {
  echo -e "\n${LIGHT_BLUE}[RELEASE] $1${NC}"
}
error() {
  echo -e "\n${RED}[RELEASE] $1${NC}"
}

ANDROID_AAB_DIR="build/app/outputs/bundle/release"

upload_ios_dsyms_to_crashlytics() {
  local dsym_dir="build/ios/archive/Runner.xcarchive/dSYMs"
  local plist="ios/Runner/GoogleService-Info.plist"
  local firebase_app_id=""
  local upload_symbols=""

  if [ -f "$plist" ]; then
    firebase_app_id=$(/usr/libexec/PlistBuddy -c "Print :GOOGLE_APP_ID" "$plist" 2>/dev/null || true)
  fi
  if [ -z "$firebase_app_id" ]; then
    error "ERROR: GOOGLE_APP_ID not found in $plist, needed to upload dSYMs to Crashlytics."
    exit 1
  fi

  if [ ! -d "$dsym_dir" ]; then
    error "ERROR: dSYM directory not found at $dsym_dir"
    exit 1
  fi

  for candidate in \
    "build/ios/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols" \
    "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols; do
    if [ -f "$candidate" ]; then
      upload_symbols="$candidate"
      break
    fi
  done

  if [ -z "$upload_symbols" ]; then
    error "ERROR: Firebase Crashlytics upload-symbols script not found."
    error "Run 'flutter build ipa --config-only' and try again."
    exit 1
  fi

  info "Uploading dSYMs to Firebase Crashlytics..."
  "$upload_symbols" -ai "$firebase_app_id" -p ios "$dsym_dir"
  success "dSYMs uploaded to Firebase Crashlytics."
}

# Reveal the release AAB in Finder for a manual Play Console upload.
open_android_aab_in_finder() {
  local aab=""
  if [ -d "$ANDROID_AAB_DIR" ]; then
    aab=$(ls -t "$ANDROID_AAB_DIR"/*.aab 2>/dev/null | head -1 || true)
  fi
  if [ -n "$aab" ] && [ -f "$aab" ]; then
    open -R "$aab"
  elif [ -d "$ANDROID_AAB_DIR" ]; then
    open "$ANDROID_AAB_DIR"
  else
    error "ERROR: Android App Bundle not found under $ANDROID_AAB_DIR"
    return 1
  fi
}

# Ask to continue with a manual Play upload, then open the AAB in Finder.
# Returns 0 if the user continues, 1 if they decline.
offer_manual_android_play_upload() {
  local reason="$1"
  error "$reason"
  info "You can keep going with a manual upload: the AAB will be shown in Finder so you can upload it in Google Play Console."
  read -p "Continue with manual upload? (y/n) [y]: " manual_choice
  manual_choice=${manual_choice:-y}
  if [[ ! "$manual_choice" =~ ^[Yy]$ ]]; then
    info "Skipping Android upload."
    return 1
  fi
  info "Opening the Android App Bundle in Finder..."
  info "Upload it in Play Console → Testing → Internal testing (or your track) → Create new release."
  open_android_aab_in_finder
  success "AAB ready for manual upload to Google Play Console."
  return 0
}

# True when PLAY_STORE_JSON_KEY_PATH is set and points to a readable file.
play_store_json_key_is_valid() {
  local play_key
  play_key=$(grep -E "^PLAY_STORE_JSON_KEY_PATH\s*=" .secret.local | cut -d '=' -f2- | xargs)
  if [ -z "$play_key" ]; then
    return 1
  fi
  if [ ! -f "$play_key" ] || [ ! -r "$play_key" ]; then
    return 1
  fi
  return 0
}

# Whether the project uses Crashlytics, whose iOS dSYMs are then uploaded after the build.
uses_crashlytics() {
  grep -Eq "^[[:space:]]+firebase_crashlytics:" pubspec.yaml
}

#####################################
# Release type selection (the web app only exists in projects with lib/main_web.dart)
#####################################
if [ -f lib/main_web.dart ]; then
  info "What would you like to release?"
  echo "1) Mobile App (default)"
  echo "2) Web App"
  echo "3) Exit"
  read -p "Choose an option (1-3) [1]: " release_choice
  release_choice=${release_choice:-1}
else
  release_choice=1
fi

if [ "$release_choice" == "3" ]; then
  info "Exiting..."
  exit 0
fi

#####################################
# Check .secret.local exists
#####################################
if [ ! -f .secret.local ]; then
  error "ERROR: .secret.local file not found."
  exit 1
fi

if [ "$release_choice" == "2" ]; then
  #####################################
  # Build and deploy Web App
  #####################################
  info "Building for Web..."
  flutter build web --release --target lib/main_web.dart
  success "Web build finished successfully."

  info "Deploying to Firebase Hosting..."
  firebase deploy --only hosting
  success "Web deployment finished successfully! 🎉"
  exit 0
fi

#####################################
# Load secrets from .secret.local file (exported for xcrun altool and Fastlane)
#####################################
info "Loading secrets from .secret.local file..."
export $(grep -v '^#' .secret.local | xargs)

#####################################
# Define the required secret keys (Mobile only)
#####################################
REQUIRED_KEYS=(
  "APP_STORE_CONNECT_API_KEY"
  "APP_STORE_CONNECT_APP_ISSUER_ID"
)

#####################################
# Check that each key has a value
#####################################
info "Validating required secrets..."
for KEY in "${REQUIRED_KEYS[@]}"; do
  VALUE=$(grep -E "^$KEY\s*=" .secret.local | cut -d '=' -f2- | xargs)
  if [ -z "$VALUE" ]; then
    error "ERROR: Key '$KEY' is missing or empty in .secret.local."
    exit 1
  fi
done
success "All required secrets are present."

#####################################
# Extract version from pubspec.yaml and check tag
# Example: version: 1.2.3+45
#####################################
info "Extracting version from pubspec.yaml..."
PUBSPEC_VERSION=$(grep -m 1 '^version:' pubspec.yaml | sed 's/version:\s*//' | xargs)
if [ -z "$PUBSPEC_VERSION" ]; then
  error "ERROR: Could not find 'version:' in pubspec.yaml"
  exit 1
fi

# Split into x.y.z and buildNumber
VERSION_PART=$(echo "$PUBSPEC_VERSION" | cut -d '+' -f1)   # e.g. 1.2.3
BUILD_PART=$(echo "$PUBSPEC_VERSION" | cut -d '+' -f2)     # e.g. 45

if [ -z "$BUILD_PART" ]; then
  error "ERROR: pubspec.yaml version does not include a build number (e.g. +45)."
  exit 1
fi

# Construct the Git tag (e.g. 1.2.3_45)
CURRENT_TAG="${VERSION_PART}+${BUILD_PART}"
info "Current version: $VERSION_PART+$BUILD_PART"

# Ensure local tags are in sync with remote
info "Fetching latest tags from remote..."
git fetch --tags

# Check if tag exists locally or remotely
if git rev-parse "$CURRENT_TAG" >/dev/null 2>&1 || git ls-remote --exit-code --tags origin "$CURRENT_TAG" >/dev/null 2>&1; then
  error "Tag '$CURRENT_TAG' already exists locally or on remote."
  info "Current version: $VERSION_PART+$BUILD_PART"
  echo ""
  info "Would you like to automatically bump the version and create a merge request?"
  echo "1) Bump patch version (default) - $VERSION_PART -> $(echo $VERSION_PART | awk -F. '{$NF = $NF + 1;} 1' | sed 's/ /./g')"
  echo "2) Bump minor version - $VERSION_PART -> $(echo $VERSION_PART | awk -F. '{$2 = $2 + 1; $3 = 0;} 1' | sed 's/ /./g')"
  echo "3) Bump major version - $VERSION_PART -> $(echo $VERSION_PART | awk -F. '{$1 = $1 + 1; $2 = 0; $3 = 0;} 1' | sed 's/ /./g')"
  echo "4) Only bump build number - $VERSION_PART+$BUILD_PART -> $VERSION_PART+$((BUILD_PART + 1))"
  echo "5) Exit"
  read -p "Choose an option (1-5) [1]: " choice
  choice=${choice:-1}

  case $choice in
    1)
      NEW_VERSION=$(echo $VERSION_PART | awk -F. '{$NF = $NF + 1;} 1' | sed 's/ /./g')
      ;;
    2)
      NEW_VERSION=$(echo $VERSION_PART | awk -F. '{$2 = $2 + 1; $3 = 0;} 1' | sed 's/ /./g')
      ;;
    3)
      NEW_VERSION=$(echo $VERSION_PART | awk -F. '{$1 = $1 + 1; $2 = 0; $3 = 0;} 1' | sed 's/ /./g')
      ;;
    4)
      NEW_VERSION=$VERSION_PART
      ;;
    5)
      info "Exiting..."
      exit 1
      ;;
    *)
      error "Invalid option. Exiting."
      exit 1
      ;;
  esac

  # Increment build number
  NEW_BUILD=$((BUILD_PART + 1))
  NEW_VERSION_FULL="$NEW_VERSION+$NEW_BUILD"
  info "New version will be: $NEW_VERSION_FULL"

  # Update pubspec.yaml with new version and build number
  info "Updating pubspec.yaml with new version..."
  sed -i '' "s/^version: .*$/version: $NEW_VERSION_FULL/" pubspec.yaml
  success "Updated pubspec.yaml to version $NEW_VERSION_FULL"
fi

#####################################
# Platform selection
#####################################
echo ""
info "Which platform(s) would you like to release for?"
echo "1) Both Android and iOS (default)"
echo "2) iOS only"
echo "3) Android only"
echo "4) Exit"
read -p "Choose an option (1-4) [1]: " platform_choice
platform_choice=${platform_choice:-1}

case $platform_choice in
  1)
    PLATFORMS=("android" "ios")
    info "Selected platforms: Android and iOS"
    ;;
  2)
    PLATFORMS=("ios")
    info "Selected platform: iOS only"
    ;;
  3)
    PLATFORMS=("android")
    info "Selected platform: Android only"
    ;;
  4)
    info "Exiting..."
    exit 0
    ;;
  *)
    error "Invalid option. Exiting."
    exit 1
    ;;
esac

#####################################
# Optional store listings with Fastlane
# Only offered in projects with a fastlane/Fastfile (lanes: validate_metadata, ios metadata,
# android upload) and Bundler installed; otherwise the release runs as usual.
#####################################
USE_FASTLANE=false
# When true, Android AAB is uploaded via Fastlane after the commit; otherwise Finder opens.
USE_ANDROID_FASTLANE=false
if [ -f fastlane/Fastfile ]; then
  if ! command -v bundle &> /dev/null; then
    error "WARNING: fastlane/Fastfile found but Bundler is not installed: store listings will not be pushed."
  else
    echo ""
    info "Push the store listings (texts, screenshots, release notes) with Fastlane?"
    info "On Android, this also uploads the app bundle as a draft on the internal testing track."
    read -p "Use Fastlane? (y/n) [n]: " fastlane_choice
    fastlane_choice=${fastlane_choice:-n}
    if [[ "$fastlane_choice" =~ ^[Yy]$ ]]; then
      if [[ " ${PLATFORMS[*]} " == *" android "* ]]; then
        if play_store_json_key_is_valid; then
          USE_ANDROID_FASTLANE=true
        else
          error "WARNING: PLAY_STORE_JSON_KEY_PATH is missing, empty, or not a readable file."
          info "Automatic Play Store upload is unavailable. You can still push iOS listings with Fastlane,"
          info "and upload the Android AAB manually after the build."
          read -p "Continue and upload Android manually later? (y/n) [y]: " manual_android_choice
          manual_android_choice=${manual_android_choice:-y}
          if [[ ! "$manual_android_choice" =~ ^[Yy]$ ]]; then
            info "Exiting..."
            exit 0
          fi
        fi
      fi
      info "Installing Fastlane..."
      bundle check > /dev/null || bundle install
      # Fails before the long builds if a store text is too long.
      bundle exec fastlane validate_metadata
      USE_FASTLANE=true
      success "Fastlane is ready."
    fi
  fi
fi

#####################################
# Run La Totale
#####################################
info "Starting La Totale..."
./scripts/la-totale.sh
success "La Totale finished successfully."

#####################################
# Optional dart_defines.json
#####################################
DART_DEFINE_ARGS=()
if [ -f dart_defines.json ]; then
  DART_DEFINE_ARGS+=(--dart-define-from-file=dart_defines.json)
  info "Using dart_defines.json for compile-time defines (incl. RevenueCat)."
else
  error "WARNING: dart_defines.json not found."
  info "Dependencies such as RevenueCat will not fully work without it."
  read -p "Continue without dart_defines.json? (y/n) [n]: " continue_without_defines
  continue_without_defines=${continue_without_defines:-n}
  if [[ ! "$continue_without_defines" =~ ^[Yy]$ ]]; then
    info "Exiting..."
    exit 0
  fi
  info "Continuing without dart_defines.json."
fi

#####################################
# Build for selected platforms
#####################################
BUILT_IOS=false
BUILT_ANDROID=false
for platform in "${PLATFORMS[@]}"; do
  info "Building for $platform..."

  case $platform in
    "android")
      info "Building Android app bundle..."
      flutter build appbundle --release --no-tree-shake-icons "${DART_DEFINE_ARGS[@]}"
      success "Android build finished successfully."
      BUILT_ANDROID=true
      if [ "$USE_ANDROID_FASTLANE" != true ] && [ "$USE_FASTLANE" != true ]; then
        # No Fastlane at all: open Finder now (upload deferred only when Fastlane is in use).
        info "Opening Android App Bundle in Finder for manual Play Console upload..."
        open_android_aab_in_finder
      fi
      ;;
    "ios")
      info "Building iOS app bundle..."

      # Check if we're on macOS for iOS builds
      if [[ "$OSTYPE" != "darwin"* ]]; then
        error "ERROR: iOS builds require macOS. Skipping iOS build."
        continue
      fi

      # Check if Xcode is available
      if ! command -v xcodebuild &> /dev/null; then
        error "ERROR: Xcode is not installed or not in PATH. Skipping iOS build."
        continue
      fi

      # Build iOS app bundle (upload happens after the version/lockfile commit)
      flutter build ipa --release --no-tree-shake-icons "${DART_DEFINE_ARGS[@]}"
      success "iOS build finished successfully."
      if uses_crashlytics; then
        upload_ios_dsyms_to_crashlytics
      else
        info "No firebase_crashlytics dependency: skipping the dSYM upload."
      fi
      BUILT_IOS=true
      ;;
  esac
done

#####################################
# Commit version bump + iOS lockfiles (after builds regenerate them)
#####################################
RELEASE_TAG="${NEW_VERSION_FULL:-$CURRENT_TAG}"
LOCKFILE_PATHS=(
  "ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  "ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  "ios/Podfile.lock"
)

info "Staging release files for commit..."
git add pubspec.yaml "${LOCKFILE_PATHS[@]}"

if ! git diff --cached --quiet; then
  if [ -n "$NEW_VERSION_FULL" ]; then
    COMMIT_MSG="Version $NEW_VERSION_FULL"
  else
    COMMIT_MSG="Update iOS dependency lockfiles"
  fi
  info "Creating commit '$COMMIT_MSG'..."
  git commit -m "$COMMIT_MSG"
  git push origin main
  success "Successfully pushed commit '$COMMIT_MSG' to remote!"
else
  info "No version or lockfile changes to commit."
fi

#####################################
# Upload iOS build and listing (after commit, so git matches what we ship)
#####################################
if [ "$BUILT_IOS" = true ]; then
  info "Uploading to App Store Connect..."
  xcrun altool --upload-app --type ios -f build/ios/ipa/*.ipa --apiKey $APP_STORE_CONNECT_API_KEY --apiIssuer $APP_STORE_CONNECT_APP_ISSUER_ID
  success "Successfully uploaded to App Store Connect!"

  if [ "$USE_FASTLANE" = true ]; then
    info "Pushing the App Store listing with Fastlane..."
    bundle exec fastlane ios metadata
    success "App Store listing pushed (not submitted for review)."
  fi
fi

#####################################
# Upload Android build and listing (after commit, like iOS)
# Fastlane when the Play JSON key is valid; otherwise (or on failure) manual via Finder.
#####################################
if [ "$BUILT_ANDROID" = true ]; then
  if [ "$USE_ANDROID_FASTLANE" = true ]; then
    info "Uploading to Google Play (internal testing, draft) with Fastlane..."
    set +e
    bundle exec fastlane android upload
    ANDROID_UPLOAD_STATUS=$?
    set -e
    if [ $ANDROID_UPLOAD_STATUS -eq 0 ]; then
      success "Successfully uploaded to Google Play!"
    else
      offer_manual_android_play_upload "Fastlane Play Store upload failed (exit $ANDROID_UPLOAD_STATUS)."
    fi
  elif [ "$USE_FASTLANE" = true ]; then
    # Fastlane used for listings/iOS; Android is manual (user already agreed when the Play key was invalid).
    info "Opening the Android App Bundle in Finder for manual Play Console upload..."
    info "Upload it in Play Console → Testing → Internal testing (or your track) → Create new release."
    open_android_aab_in_finder
    success "AAB ready for manual upload to Google Play Console."
  fi
fi

#####################################
# Create and push Git tag
#####################################
info "Preparing to tag release as '$RELEASE_TAG'..."

# Create a new annotated tag
git tag -a "$RELEASE_TAG" -m "Release $RELEASE_TAG"

# Push the new tag to remote
git push origin "$RELEASE_TAG"

success "Successfully pushed tag '$RELEASE_TAG' to remote!"
success "Release process completed successfully! 🎉"
