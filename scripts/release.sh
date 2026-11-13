#!/usr/bin/env bash
#
# Shared release script of the Flutter template, symlinked into every app as scripts/release.sh
# and run from anywhere in the project. It handles two kinds of projects:
#
# - Flutter (pubspec.yaml): version in pubspec.yaml; builds with `flutter build`, uploads the IPA
#   with `xcrun altool`, and the store texts and Android bundle with the shared Fastfile lanes
#   (`ios metadata`, `android upload`); optional web release to Firebase Hosting.
# - Native iOS (an .xcodeproj at the root): version in MARKETING_VERSION / CURRENT_PROJECT_VERSION;
#   builds and uploads with the project's own Fastfile, which provides `ios build` (archive and
#   export the IPA) and `ios upload` (IPA and App Store texts, no review submission).
#
# Both: version bump, release notes written with AI when missing (scripts/write-changelog.py),
# optional project hooks (scripts/release-hooks/pre-build.sh before the build, post-upload.sh
# after the uploads), then a release commit and tag pushed before any upload. Full description in
# the Flutter template README ("Releases") and agents/rules/release.md.

# The whole script is one { ... } block: bash parses it all before running, so editing this file
# (or pulling a new version of it) during a release cannot make the running release execute garbage.
{

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

#####################################
# Project root and type
#####################################
# The project root is the parent of the scripts folder holding the symlink.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

if [ -f pubspec.yaml ]; then
  PROJECT_TYPE="flutter"
else
  XCODE_PROJECT=$(ls -d ./*.xcodeproj 2>/dev/null | head -1 || true)
  XCODE_PROJECT=${XCODE_PROJECT#./}
  if [ -z "$XCODE_PROJECT" ]; then
    error "ERROR: $PROJECT_ROOT has neither pubspec.yaml (Flutter) nor an .xcodeproj (native iOS)."
    exit 1
  fi
  PROJECT_TYPE="ios"
  PBXPROJ="$XCODE_PROJECT/project.pbxproj"
fi

# Homebrew Ruby (Fastlane needs Ruby 3+, macOS ships 2.6)
if [ -x "/opt/homebrew/opt/ruby/bin/ruby" ]; then
  export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:${PATH}"
elif [ -x "/usr/local/opt/ruby/bin/ruby" ]; then
  export PATH="/usr/local/opt/ruby/bin:/usr/local/bin:${PATH}"
fi
# Avoid an inherited BUNDLE_PATH pointing at a missing directory
unset BUNDLE_PATH

ANDROID_AAB_DIR="build/app/outputs/bundle/release"

#####################################
# Helpers
#####################################

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

# Folder of the App Store texts: fastlane/metadata/ios in Flutter projects (next to android),
# fastlane/metadata itself in native iOS projects.
ios_metadata_dir() {
  if [ "$PROJECT_TYPE" = "flutter" ]; then
    echo "fastlane/metadata/ios"
  else
    echo "fastlane/metadata"
  fi
}

# Store locale folders (ios or android) of the project, one per line.
release_notes_locales() {
  local root dir name
  if [ "$1" = "ios" ]; then
    root=$(ios_metadata_dir)
  elif [ "$PROJECT_TYPE" = "flutter" ]; then
    root="fastlane/metadata/android"
  else
    return 0
  fi
  for dir in "$root"/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    if [[ "$name" =~ ^[a-z]{2,3}(-[A-Za-z0-9]+)*$ ]]; then
      echo "$name"
    fi
  done
}

# True when fastlane/release_notes_version.txt names the version being released and every store
# locale has its notes (scripts/changelog-format.md).
release_notes_are_current() {
  local locale ios_dir
  ios_dir=$(ios_metadata_dir)
  if [ "$(tr -d '[:space:]' 2>/dev/null < fastlane/release_notes_version.txt)" != "$RELEASE_VERSION" ]; then
    return 1
  fi
  for locale in $(release_notes_locales ios); do
    [ -s "$ios_dir/$locale/release_notes.txt" ] || return 1
  done
  for locale in $(release_notes_locales android); do
    [ -s "fastlane/metadata/android/$locale/changelogs/default.txt" ] \
      || [ -s "fastlane/metadata/android/$locale/changelogs/$RELEASE_BUILD.txt" ] || return 1
  done
  return 0
}

# Writes the localized release notes of this version with AI (scripts/write-changelog.py) when
# they are missing. They stay uncommitted until the release commit, after the builds.
write_release_notes_if_needed() {
  if [ -z "$(release_notes_locales ios)$(release_notes_locales android)" ]; then
    return 0
  fi
  if release_notes_are_current; then
    info "Release notes already written for $RELEASE_VERSION."
    return 0
  fi
  local status=1
  if [ -x scripts/write-changelog.py ]; then
    info "No release notes for $RELEASE_VERSION yet: writing them with AI..."
    set +e
    RELEASE_VERSION="$RELEASE_VERSION" RELEASE_BUILD="$RELEASE_BUILD" RELEASE_TAG="$RELEASE_TAG" \
      ./scripts/write-changelog.py
    status=$?
    set -e
  else
    error "scripts/write-changelog.py not found: the release notes cannot be written automatically."
  fi
  if [ $status -eq 0 ]; then
    success "Release notes written: they are uploaded with this release and committed with it."
    return 0
  elif [ $status -eq 3 ]; then
    return 0
  fi
  error "The $RELEASE_VERSION release notes were not written."
  info "Write them by hand (scripts/changelog-format.md) and put $RELEASE_VERSION in"
  info "fastlane/release_notes_version.txt, or keep the current notes."
  read -p "Continue with the current release notes? (y/n) [n]: " keep_notes_choice
  keep_notes_choice=${keep_notes_choice:-n}
  if [[ ! "$keep_notes_choice" =~ ^[Yy]$ ]]; then
    info "Exiting..."
    exit 1
  fi
}

# For a manual Play Console upload: gathers the Play release notes of every locale
# (changelogs/<build>.txt, else default.txt) in the Console's multi-language format, copies them
# to the clipboard and opens them in the default text editor, to paste into "Release notes".
open_android_release_notes() {
  local notes_file="$ANDROID_AAB_DIR/release-notes.txt"
  local locale notes found=false
  mkdir -p "$ANDROID_AAB_DIR"
  : > "$notes_file"
  for locale in $(release_notes_locales android); do
    notes="fastlane/metadata/android/$locale/changelogs/$RELEASE_BUILD.txt"
    [ -s "$notes" ] || notes="fastlane/metadata/android/$locale/changelogs/default.txt"
    [ -s "$notes" ] || continue
    printf '<%s>\n%s\n</%s>\n' "$locale" "$(cat "$notes")" "$locale" >> "$notes_file"
    found=true
  done
  if [ "$found" != true ]; then
    info "No Google Play release notes in fastlane/metadata/android: write them in Play Console."
    return 0
  fi
  if [ "$(tr -d '[:space:]' 2>/dev/null < fastlane/release_notes_version.txt)" != "$RELEASE_VERSION" ]; then
    error "WARNING: fastlane/release_notes_version.txt does not name $RELEASE_VERSION: these notes may be from another version."
  fi
  pbcopy < "$notes_file" 2>/dev/null || true
  open -t "$notes_file" 2>/dev/null || true
  info "Google Play release notes copied to the clipboard and opened ($notes_file):"
  info "paste them into the release's \"Release notes\" field, all languages at once."
}

# Reveal the release AAB in Finder for a manual Play Console upload, with its release notes.
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
  open_android_release_notes
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
  local play_key="${PLAY_STORE_JSON_KEY_PATH:-}"
  play_key="${play_key/#\~/$HOME}"
  [ -n "$play_key" ] && [ -f "$play_key" ] && [ -r "$play_key" ]
}

# A value of android/key.properties, trimmed.
key_property() {
  grep -E "^$1[[:space:]]*=" android/key.properties | head -1 | cut -d '=' -f2- \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# keytool from the PATH, JAVA_HOME or Android Studio's bundled JDK (macOS has a /usr/bin/keytool
# stub that fails without a JDK).
find_keytool() {
  local candidate
  for candidate in "$(command -v keytool 2>/dev/null)" "${JAVA_HOME:-}/bin/keytool" \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -help > /dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# SHA-256 fingerprint of a certificate listing from keytool.
sha256_of() {
  grep -E "SHA256:" | head -1 | sed 's/.*SHA256:[[:space:]]*//' | tr -d '[:space:]'
}

# Fails unless android/key.properties holds a usable upload key, and keeps its certificate
# fingerprint in UPLOAD_CERT_SHA256 to check the built bundle against.
check_android_upload_key() {
  local store_file store_password key_alias key_password keystore name
  UPLOAD_CERT_SHA256=""
  if [ ! -f android/key.properties ]; then
    error "ERROR: android/key.properties not found: Google Play only accepts app bundles signed with"
    error "the app's upload key. Get it from the app's 1Password item (see the Flutter template"
    error "README, \"Android upload key\"), or release iOS only."
    exit 1
  fi
  store_file=$(key_property storeFile)
  store_password=$(key_property storePassword)
  key_alias=$(key_property keyAlias)
  key_password=$(key_property keyPassword)
  for name in storeFile storePassword keyAlias keyPassword; do
    if [ -z "$(key_property "$name")" ]; then
      error "ERROR: '$name' is missing or empty in android/key.properties."
      exit 1
    fi
  done
  # Gradle resolves storeFile from android/app with file(), or from android with rootProject.file().
  if [[ "$store_file" == /* ]]; then
    keystore="$store_file"
  elif [ -f "android/app/$store_file" ]; then
    keystore="android/app/$store_file"
  else
    keystore="android/$store_file"
  fi
  if [ ! -f "$keystore" ]; then
    error "ERROR: Upload keystore not found at android/app/$store_file (storeFile in android/key.properties)."
    error "Download upload-keystore.jks from the app's 1Password item into android/app."
    exit 1
  fi
  if ! KEYTOOL=$(find_keytool); then
    error "WARNING: keytool not found (install a JDK or Android Studio): the upload key passwords"
    error "and the signature of the app bundle cannot be checked."
    return 0
  fi
  if ! "$KEYTOOL" -list -keystore "$keystore" -storepass "$store_password" -alias "$key_alias" > /dev/null 2>&1; then
    error "ERROR: Cannot open alias '$key_alias' of $keystore: check storePassword and keyAlias in android/key.properties."
    exit 1
  fi
  # keytool ignores -keypass with PKCS12 (the default keystore type), whose key is protected by
  # the store password: Gradle then needs keyPassword to be the same.
  if "$KEYTOOL" -list -keystore "$keystore" -storepass "$store_password" 2>/dev/null | grep -qi "type: PKCS12"; then
    if [ "$key_password" != "$store_password" ]; then
      error "ERROR: keyPassword must equal storePassword for the PKCS12 keystore $keystore (android/key.properties)."
      exit 1
    fi
  elif ! "$KEYTOOL" -certreq -keystore "$keystore" -storepass "$store_password" -alias "$key_alias" \
    -keypass "$key_password" > /dev/null 2>&1; then
    error "ERROR: Cannot use key '$key_alias' of $keystore: check keyPassword in android/key.properties."
    exit 1
  fi
  UPLOAD_CERT_SHA256=$("$KEYTOOL" -list -v -keystore "$keystore" -storepass "$store_password" \
    -alias "$key_alias" 2>/dev/null | sha256_of)
  success "Android upload key found in android/key.properties."
}

# Fails unless the built app bundle is signed with the upload key of android/key.properties
# (e.g. android/app/build.gradle.kts does not read it and falls back to the debug keys).
check_android_bundle_signature() {
  local aab bundle_sha256
  [ -n "$UPLOAD_CERT_SHA256" ] || return 0
  aab=$(ls -t "$ANDROID_AAB_DIR"/*.aab 2>/dev/null | head -1 || true)
  bundle_sha256=$("$KEYTOOL" -printcert -jarfile "$aab" 2>/dev/null | sha256_of)
  if [ "$bundle_sha256" != "$UPLOAD_CERT_SHA256" ]; then
    error "ERROR: $aab is not signed with the upload key of android/key.properties."
    error "Make android/app/build.gradle.kts sign release builds with it (see the Flutter template"
    error "README, \"Android upload key\"). Nothing was committed, tagged or uploaded."
    exit 1
  fi
  success "App bundle signed with the upload key."
}

# Whether the project uses Crashlytics, whose iOS dSYMs are then uploaded after the build.
uses_crashlytics() {
  grep -Eq "^[[:space:]]+firebase_crashlytics:" pubspec.yaml
}

# Whether the project's Fastfile defines a lane (e.g. "validate_metadata").
fastfile_has_lane() {
  grep -Eq "lane[[:space:]]+:$1([^a-z_]|$)" fastlane/Fastfile 2>/dev/null
}

# Runs scripts/release-hooks/<stage>.sh when it exists and is executable. Stages: pre-build
# (after the release notes, before the build; a failure aborts the release) and post-upload.
run_release_hook() {
  local hook="scripts/release-hooks/$1.sh"
  if [ ! -x "$hook" ]; then
    return 0
  fi
  info "Running release hook '$1'..."
  RELEASE_VERSION="$RELEASE_VERSION" RELEASE_BUILD="$RELEASE_BUILD" RELEASE_TAG="$RELEASE_TAG" "./$hook"
  success "Release hook '$1' finished."
}

# Version of a native iOS project (the first MARKETING_VERSION / CURRENT_PROJECT_VERSION).
read_xcode_setting() {
  grep -m 1 "$1 = " "$PBXPROJ" | sed -E "s/.*$1 = \"?([^;\"]+)\"?;/\1/" | xargs
}

#####################################
# Release type selection (the web app only exists in Flutter projects with lib/main_web.dart)
#####################################
if [ "$PROJECT_TYPE" = "flutter" ] && [ -f lib/main_web.dart ]; then
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
  error "ERROR: .secret.local file not found (copy .secret.local.example from the Flutter template)."
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
# Load secrets from .secret.local (exported for altool, Fastlane and the release notes writer)
#####################################
info "Loading secrets from .secret.local..."
set -a
# shellcheck disable=SC1091
source .secret.local
set +a

#####################################
# Uncommitted changes would be built but left out of the release commit and tag.
#####################################
if [ -n "$(git status --porcelain)" ]; then
  error "WARNING: The working tree has uncommitted changes. They would be built into this release"
  error "but left out of its commit and tag:"
  git status --short
  read -p "Release anyway? (y/n) [n]: " dirty_choice
  dirty_choice=${dirty_choice:-n}
  if [[ ! "$dirty_choice" =~ ^[Yy]$ ]]; then
    info "Exiting..."
    exit 0
  fi
fi

#####################################
# Release files: the version, release notes and lockfiles the release changes, then commits.
#####################################
if [ "$PROJECT_TYPE" = "flutter" ]; then
  RELEASE_PATHS=(
    "pubspec.yaml"
    "ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    "ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    "ios/Podfile.lock"
  )
else
  RELEASE_PATHS=(
    "$PBXPROJ"
    "$XCODE_PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  )
fi
# Release notes written for this release (and any store text edited before releasing)
RELEASE_PATHS+=("fastlane/metadata" "fastlane/release_notes_version.txt")

#####################################
# Atomic release: from here until the release commit, any exit (a choice to stop, an error,
# Ctrl-C) puts the release files back as they were, so an aborted release leaves no version
# bump or half-written release notes behind. Changes made before the release (the "Release
# anyway" case above) are kept: the snapshot includes them.
#####################################
ROLLBACK_SNAPSHOT=$(git stash create 2>/dev/null || true)
if [ -n "$ROLLBACK_SNAPSHOT" ]; then
  # A stash commit's second parent holds the index (staged changes)
  ROLLBACK_INDEX="$ROLLBACK_SNAPSHOT^2"
else
  ROLLBACK_SNAPSHOT=$(git rev-parse HEAD)
  ROLLBACK_INDEX=$ROLLBACK_SNAPSHOT
fi
ROLLBACK_UNTRACKED=$(git ls-files --others --exclude-standard -- "${RELEASE_PATHS[@]}")
ROLLBACK_ACTIVE=true

rollback_release_files() {
  [ "$ROLLBACK_ACTIVE" = true ] || return 0
  ROLLBACK_ACTIVE=false
  set +e
  local changed=() created=() path
  while IFS= read -r path; do
    [ -n "$path" ] && changed+=("$path")
  done < <(git diff --name-only "$ROLLBACK_SNAPSHOT" -- "${RELEASE_PATHS[@]}")
  while IFS= read -r path; do
    [ -n "$path" ] && ! grep -qxF "$path" <<< "$ROLLBACK_UNTRACKED" && created+=("$path")
  done < <(git ls-files --others --exclude-standard -- "${RELEASE_PATHS[@]}")
  if [ ${#changed[@]} -eq 0 ] && [ ${#created[@]} -eq 0 ]; then
    return 0
  fi
  info "Rolling back the release files..."
  if [ ${#changed[@]} -gt 0 ]; then
    git restore --source="$ROLLBACK_INDEX" --staged -- "${changed[@]}"
    git restore --source="$ROLLBACK_SNAPSHOT" --worktree -- "${changed[@]}"
  fi
  if [ ${#created[@]} -gt 0 ]; then
    rm -f -- "${created[@]}"
    for path in "${created[@]}"; do
      rmdir -p "$(dirname "$path")" 2>/dev/null
    done
  fi
  printf '  %s\n' "${changed[@]}" "${created[@]}"
  success "Release files rolled back."
}
trap rollback_release_files EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

#####################################
# Platform selection (Flutter projects with both platforms)
#####################################
if [ "$PROJECT_TYPE" = "flutter" ] && [ -d android ] && [ -d ios ]; then
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
elif [ "$PROJECT_TYPE" = "flutter" ] && [ -d android ]; then
  PLATFORMS=("android")
else
  PLATFORMS=("ios")
fi

#####################################
# Xcode (Flutter iOS builds): checked before anything changes rather than after La Totale and the
# Android build.
#####################################
if [ "$PROJECT_TYPE" = "flutter" ] && [[ " ${PLATFORMS[*]} " == *" ios "* ]] \
  && ! command -v xcodebuild &> /dev/null; then
  error "ERROR: Xcode is not installed or not in PATH."
  if [[ " ${PLATFORMS[*]} " == *" android "* ]]; then
    read -p "Release Android only? (y/n) [n]: " android_only_choice
    android_only_choice=${android_only_choice:-n}
    if [[ ! "$android_only_choice" =~ ^[Yy]$ ]]; then
      info "Exiting..."
      exit 0
    fi
    PLATFORMS=("android")
    info "Selected platform: Android only"
  else
    exit 1
  fi
fi

#####################################
# App Store Connect API key. Two namings are accepted: APP_STORE_CONNECT_API_KEY /
# APP_STORE_CONNECT_APP_ISSUER_ID / APP_STORE_CONNECT_API_KEY_PATH (the template's), or
# APP_STORE_CONNECT_API_KEY_KEY_ID / _ISSUER_ID / _KEY_FILEPATH. The file defaults to
# AuthKey_<key id>.p8 in altool's folders. Checked whenever iOS is released: a missing or
# misnamed key stops the release before anything changes.
#####################################
if [[ " ${PLATFORMS[*]} " == *" ios "* ]]; then
  info "Validating the App Store Connect API key..."
  ASC_KEY_ID="${APP_STORE_CONNECT_API_KEY_KEY_ID:-${APP_STORE_CONNECT_API_KEY:-}}"
  ASC_ISSUER_ID="${APP_STORE_CONNECT_API_KEY_ISSUER_ID:-${APP_STORE_CONNECT_APP_ISSUER_ID:-}}"
  ASC_KEY_PATH="${APP_STORE_CONNECT_API_KEY_KEY_FILEPATH:-${APP_STORE_CONNECT_API_KEY_PATH:-}}"
  if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ]; then
    error "ERROR: APP_STORE_CONNECT_API_KEY and APP_STORE_CONNECT_APP_ISSUER_ID must be set in .secret.local."
    exit 1
  fi
  if [ -n "$ASC_KEY_PATH" ]; then
    ASC_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"
    [[ "$ASC_KEY_PATH" == /* ]] || ASC_KEY_PATH="$PROJECT_ROOT/${ASC_KEY_PATH#./}"
  else
    for dir in ./private_keys "$HOME/private_keys" "$HOME/.private_keys" "$HOME/.appstoreconnect/private_keys"; do
      if [ -f "$dir/AuthKey_$ASC_KEY_ID.p8" ]; then
        ASC_KEY_PATH="$(cd "$dir" && pwd)/AuthKey_$ASC_KEY_ID.p8"
        break
      fi
    done
  fi
  if [ -z "$ASC_KEY_PATH" ] || [ ! -f "$ASC_KEY_PATH" ]; then
    error "ERROR: App Store Connect API key file not found: set APP_STORE_CONNECT_API_KEY_PATH in .secret.local."
    exit 1
  fi
  export APP_STORE_CONNECT_API_KEY_KEY_ID="$ASC_KEY_ID"
  export APP_STORE_CONNECT_API_KEY_ISSUER_ID="$ASC_ISSUER_ID"
  export APP_STORE_CONNECT_API_KEY_KEY_FILEPATH="$ASC_KEY_PATH"
  if [ "$PROJECT_TYPE" = "flutter" ]; then
    export APP_STORE_CONNECT_API_KEY="$ASC_KEY_ID"
    export APP_STORE_CONNECT_APP_ISSUER_ID="$ASC_ISSUER_ID"
    export APP_STORE_CONNECT_API_KEY_PATH="$ASC_KEY_PATH"
  else
    # Fastlane reserves APP_STORE_CONNECT_API_KEY for its api_key Hash: never the key id there.
    unset APP_STORE_CONNECT_API_KEY
  fi
  # altool ignores APP_STORE_CONNECT_API_KEY_PATH; it only searches fixed dirs (./private_keys,
  # ~/private_keys, …) or $API_PRIVATE_KEYS_DIR for AuthKey_<key id>.p8.
  if [ "$PROJECT_TYPE" = "flutter" ] && [ "$(basename "$ASC_KEY_PATH")" != "AuthKey_${ASC_KEY_ID}.p8" ]; then
    error "ERROR: The App Store Connect key file must be named 'AuthKey_${ASC_KEY_ID}.p8' (got '$(basename "$ASC_KEY_PATH")')."
    exit 1
  fi
  success "App Store Connect API key found."
fi

#####################################
# Android upload key (android/key.properties, read by android/app/build.gradle.kts). Gradle signs
# the app bundle with it at build time and Fastlane only uploads it: Google Play refuses any
# other key, automatically or by hand. Checked before anything changes.
#####################################
if [[ " ${PLATFORMS[*]} " == *" android "* ]]; then
  check_android_upload_key
fi

#####################################
# Optional dart_defines.json (compile-time defines such as RevenueCat). Checked before anything
# changes, ahead of the release notes, Fastlane and the long builds.
#####################################
DART_DEFINE_ARGS=()
if [ "$PROJECT_TYPE" = "flutter" ]; then
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
fi

#####################################
# Fastlane: store texts and uploads. Flutter projects use it when fastlane/Fastfile exists and
# Bundler is installed (otherwise the IPA is still uploaded with altool and the AAB shown in
# Finder); native iOS projects need it to build and upload. Only checked here: it is installed
# later, once the version is set.
#####################################
FASTLANE_AVAILABLE=false
# When true, Android AAB is uploaded via Fastlane after the commit; otherwise Finder opens.
USE_ANDROID_FASTLANE=false
if [ "$PROJECT_TYPE" = "ios" ]; then
  if [ ! -f fastlane/Fastfile ] || ! fastfile_has_lane build || ! fastfile_has_lane upload; then
    error "ERROR: Native iOS projects need a fastlane/Fastfile with the 'ios build' and 'ios upload' lanes."
    exit 1
  fi
  if ! command -v bundle &> /dev/null; then
    error "ERROR: Bundler is not installed (gem install bundler)."
    exit 1
  fi
fi
if [ -f fastlane/Fastfile ]; then
  if ! command -v bundle &> /dev/null; then
    error "WARNING: fastlane/Fastfile found but Bundler is not installed: store texts will not be pushed."
  else
    if [[ " ${PLATFORMS[*]} " == *" android "* ]]; then
      info "On Android, Fastlane uploads the app bundle as a draft on the internal testing track."
      if play_store_json_key_is_valid; then
        USE_ANDROID_FASTLANE=true
      else
        error "WARNING: PLAY_STORE_JSON_KEY_PATH is missing, empty, or not a readable file."
        info "Automatic Play Store upload is unavailable: you can upload the Android AAB manually after the build."
        read -p "Continue and upload Android manually later? (y/n) [y]: " manual_android_choice
        manual_android_choice=${manual_android_choice:-y}
        if [[ ! "$manual_android_choice" =~ ^[Yy]$ ]]; then
          info "Exiting..."
          exit 0
        fi
      fi
    fi
    FASTLANE_AVAILABLE=true
  fi
fi

#####################################
# Read the current version
#####################################
if [ "$PROJECT_TYPE" = "flutter" ]; then
  # Example: version: 1.2.3+45
  info "Reading the version from pubspec.yaml..."
  PUBSPEC_VERSION=$(grep -m 1 '^version:' pubspec.yaml | sed 's/version:\s*//' | xargs)
  VERSION_PART=$(echo "$PUBSPEC_VERSION" | cut -d '+' -f1)   # e.g. 1.2.3
  BUILD_PART=$(echo "$PUBSPEC_VERSION" | cut -s -d '+' -f2)  # e.g. 45
  if [ -z "$VERSION_PART" ] || [ -z "$BUILD_PART" ]; then
    error "ERROR: pubspec.yaml needs a version with a build number (e.g. version: 1.2.3+45)."
    exit 1
  fi
else
  info "Reading the version from $PBXPROJ..."
  VERSION_PART=$(read_xcode_setting MARKETING_VERSION)
  BUILD_PART=$(read_xcode_setting CURRENT_PROJECT_VERSION)
  if [ -z "$VERSION_PART" ] || ! [[ "$BUILD_PART" =~ ^[0-9]+$ ]]; then
    error "ERROR: Could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION from $PBXPROJ."
    exit 1
  fi
fi

# Ensure local tags are in sync with remote (non-interactive: HTTPS remotes would otherwise hang
# on a username prompt)
info "Fetching latest tags from remote..."
if ! GIT_TERMINAL_PROMPT=0 git fetch --tags; then
  error "ERROR: Could not fetch tags from $(git remote get-url origin). Fix the git credentials, then retry."
  exit 1
fi

#####################################
# Tags and versions
# Releases are tagged <version>+<build> (1.3+45). Projects whose tags already use
# <version>_<build> (7.3_15, or 7.3 for build 1) keep that style.
#####################################
if git tag -l | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?_[0-9]+$' \
  && ! git tag -l | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?\+[0-9]+$'; then
  TAG_STYLE="underscore"
else
  TAG_STYLE="plus"
fi

tag_for() {
  if [ "$TAG_STYLE" = "plus" ]; then
    echo "$1+$2"
  elif [ "$2" = "1" ]; then
    echo "$1"
  else
    echo "$1_$2"
  fi
}

commit_message_for() {
  if [ "$TAG_STYLE" = "plus" ]; then
    echo "Version $1+$2"
  elif [ "$2" = "1" ]; then
    echo "Version $1"
  else
    echo "Version $1 ($2)"
  fi
}

# Release versions never carry a ".0" patch (1.3, not 1.3.0); a patch above 0 is kept (1.3.1).
# pubspec.yaml still needs a full x.y.z (Flutter refuses 1.3+45), so it keeps 1.3.0 while the
# stores (--build-name), the tag and the commit message use 1.3.
short_version() {
  echo "$1" | sed -E 's/^([0-9]+\.[0-9]+)\.0$/\1/'
}

pubspec_version() {
  echo "$1" | awk -F. '{ print ($1 + 0) "." ($2 + 0) "." ($3 + 0) }'
}

tag_exists_for_version() {
  git tag -l "$1+*" "$1_*" "$1" | grep -q .
}

# A version already released as x.y.0 keeps that form: current versions are never rewritten.
release_version_for() {
  local short
  short=$(short_version "$1")
  if [ "$short" != "$1" ] && tag_exists_for_version "$1" && ! tag_exists_for_version "$short"; then
    echo "$1"
  else
    echo "$short"
  fi
}

bump_patch() {
  echo "$1" | awk -F. '{ print ($1 + 0) "." ($2 + 0) "." ($3 + 1) }'
}

bump_minor() {
  echo "$1" | awk -F. '{ print ($1 + 0) "." ($2 + 1) }'
}

bump_major() {
  echo "$1" | awk -F. '{ print ($1 + 1) ".0" }'
}

tag_exists() {
  git rev-parse "$1" >/dev/null 2>&1 \
    || GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null 2>&1
}

if [ "$PROJECT_TYPE" = "flutter" ]; then
  RELEASE_VERSION=$(release_version_for "$VERSION_PART")
else
  # MARKETING_VERSION is what the binary ships: the tag follows it as written.
  RELEASE_VERSION="$VERSION_PART"
fi
RELEASE_BUILD="$BUILD_PART"
CURRENT_TAG=$(tag_for "$RELEASE_VERSION" "$RELEASE_BUILD")
info "Current version: $RELEASE_VERSION (build $RELEASE_BUILD), tag $CURRENT_TAG"

# The tags hold every build number already uploaded, whatever its version: the stores (Google
# Play above all) refuse to reuse one.
HIGHEST_TAG_BUILD=$(git tag -l | sed -nE 's/^[0-9]+\.[0-9]+(\.[0-9]+)?[+_]([0-9]+)$/\2/p' | sort -n | tail -1)
HIGHEST_TAG_BUILD=${HIGHEST_TAG_BUILD:-0}
# Next build number: one past both the project and the highest tag
NEXT_BUILD=$(( (BUILD_PART > HIGHEST_TAG_BUILD ? BUILD_PART : HIGHEST_TAG_BUILD) + 1 ))

VERSION_BUMPED=false
# Bump when the tag exists locally or remotely, or when its build number was already released
if tag_exists "$CURRENT_TAG" || [ "$BUILD_PART" -le "$HIGHEST_TAG_BUILD" ]; then
  if [ "$BUILD_PART" -le "$HIGHEST_TAG_BUILD" ]; then
    error "Build number $BUILD_PART was already released (highest tagged build: $HIGHEST_TAG_BUILD)."
  else
    error "Tag '$CURRENT_TAG' already exists locally or on remote."
  fi
  echo ""
  info "Would you like to bump the version?"
  echo "1) Bump patch version (default) - $RELEASE_VERSION -> $(bump_patch "$VERSION_PART") ($NEXT_BUILD)"
  echo "2) Bump minor version - $RELEASE_VERSION -> $(bump_minor "$VERSION_PART") ($NEXT_BUILD)"
  echo "3) Bump major version - $RELEASE_VERSION -> $(bump_major "$VERSION_PART") ($NEXT_BUILD)"
  echo "4) Only bump build number - $RELEASE_VERSION ($BUILD_PART) -> $RELEASE_VERSION ($NEXT_BUILD)"
  echo "5) Exit"
  read -p "Choose an option (1-5) [1]: " choice
  choice=${choice:-1}

  case $choice in
    1) RELEASE_VERSION=$(bump_patch "$VERSION_PART") ;;
    2) RELEASE_VERSION=$(bump_minor "$VERSION_PART") ;;
    3) RELEASE_VERSION=$(bump_major "$VERSION_PART") ;;
    4) ;;
    5)
      info "Exiting..."
      exit 1
      ;;
    *)
      error "Invalid option. Exiting."
      exit 1
      ;;
  esac

  RELEASE_BUILD=$NEXT_BUILD
  VERSION_BUMPED=true
  info "New version will be: $RELEASE_VERSION (build $RELEASE_BUILD)"

  if [ "$PROJECT_TYPE" = "flutter" ]; then
    PUBSPEC_VERSION_FULL="$(pubspec_version "$RELEASE_VERSION")+$RELEASE_BUILD"
    sed -i '' "s/^version: .*$/version: $PUBSPEC_VERSION_FULL/" pubspec.yaml
    success "Updated pubspec.yaml to version $PUBSPEC_VERSION_FULL"
  else
    /usr/bin/sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $RELEASE_VERSION;/g" "$PBXPROJ"
    /usr/bin/sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $RELEASE_BUILD;/g" "$PBXPROJ"
    success "Updated $PBXPROJ to $RELEASE_VERSION ($RELEASE_BUILD)"
  fi
fi

RELEASE_TAG=$(tag_for "$RELEASE_VERSION" "$RELEASE_BUILD")
if tag_exists "$RELEASE_TAG"; then
  error "ERROR: Tag '$RELEASE_TAG' already exists. Aborting."
  exit 1
fi

#####################################
# Fastlane (checked above): install it, write the missing release notes for this version with
# AI, then validate the store texts.
#####################################
USE_FASTLANE=false
if [ "$FASTLANE_AVAILABLE" = true ]; then
  info "Installing Fastlane..."
  bundle check > /dev/null 2>&1 || bundle install
  write_release_notes_if_needed
  # Fails before the long builds if a store text is too long.
  if fastfile_has_lane validate_metadata; then
    bundle exec fastlane validate_metadata
  fi
  USE_FASTLANE=true
  success "Fastlane is ready."
fi

run_release_hook pre-build

#####################################
# Build
#####################################
BUILT_IOS=false
BUILT_ANDROID=false
if [ "$PROJECT_TYPE" = "ios" ]; then
  info "Building with Fastlane (ios build)..."
  bundle exec fastlane ios build
  success "iOS build finished successfully."
  BUILT_IOS=true
else
  info "Starting La Totale..."
  ./scripts/la-totale.sh
  success "La Totale finished successfully."

  for platform in "${PLATFORMS[@]}"; do
    case $platform in
      "android")
        info "Building Android app bundle..."
        flutter build appbundle --release --no-tree-shake-icons --build-name "$RELEASE_VERSION" \
          --build-number "$RELEASE_BUILD" "${DART_DEFINE_ARGS[@]}"
        success "Android build finished successfully."
        check_android_bundle_signature
        BUILT_ANDROID=true
        if [ "$USE_ANDROID_FASTLANE" != true ] && [ "$USE_FASTLANE" != true ]; then
          # No Fastlane at all: open Finder now (upload deferred only when Fastlane is in use).
          info "Opening Android App Bundle in Finder for manual Play Console upload..."
          open_android_aab_in_finder
        fi
        ;;
      "ios")
        info "Building iOS app bundle..."
        # Upload happens after the version/lockfile commit
        rm -rf build/ios/ipa
        flutter build ipa --release --no-tree-shake-icons --build-name "$RELEASE_VERSION" \
          --build-number "$RELEASE_BUILD" "${DART_DEFINE_ARGS[@]}"
        # flutter exits 0 when only the IPA export fails (e.g. missing provisioning profile)
        if ! ls build/ios/ipa/*.ipa &> /dev/null; then
          error "ERROR: No IPA was exported to build/ios/ipa. Check the signing errors above."
          exit 1
        fi
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
fi

#####################################
# Commit the version, release notes and lockfiles (after the builds regenerate them)
#####################################
info "Staging release files for commit..."
# Only the files in use exist (e.g. SwiftPM or CocoaPods lockfiles)
for release_path in "${RELEASE_PATHS[@]}"; do
  if [ -e "$release_path" ]; then
    git add "$release_path"
  fi
done

if ! git diff --cached --quiet; then
  if [ "$VERSION_BUMPED" = true ]; then
    COMMIT_MSG=$(commit_message_for "$RELEASE_VERSION" "$RELEASE_BUILD")
  else
    COMMIT_MSG="Update release files for $RELEASE_TAG"
  fi
  info "Creating commit '$COMMIT_MSG'..."
  git commit -m "$COMMIT_MSG"
  # Committed: the release files are no longer rolled back on exit.
  ROLLBACK_ACTIVE=false
  git push origin HEAD
  success "Successfully pushed commit '$COMMIT_MSG' to remote!"
else
  info "No version, release notes or lockfile changes to commit."
  ROLLBACK_ACTIVE=false
fi

#####################################
# Create and push Git tag
# Before the uploads: a failure after a build reached a store would otherwise leave that build
# number untagged, and the next release would reuse it.
#####################################
info "Tagging the release as '$RELEASE_TAG'..."
git tag -a "$RELEASE_TAG" -m "Release $RELEASE_TAG"
git push origin "$RELEASE_TAG"
success "Successfully pushed tag '$RELEASE_TAG' to remote!"

#####################################
# Upload iOS build and App Store texts (after the commit, so git matches what we ship)
#####################################
if [ "$BUILT_IOS" = true ] && [ "$PROJECT_TYPE" = "ios" ]; then
  info "Uploading with Fastlane (ios upload: build and App Store texts, no review submission)..."
  bundle exec fastlane ios upload
  success "Successfully uploaded to App Store Connect!"
elif [ "$BUILT_IOS" = true ]; then
  # altool only searches fixed dirs or $API_PRIVATE_KEYS_DIR for AuthKey_<key id>.p8 (name
  # checked with the key, before the build).
  export API_PRIVATE_KEYS_DIR="$(dirname "$ASC_KEY_PATH")"

  info "Uploading to App Store Connect..."
  xcrun altool --upload-app --type ios -f build/ios/ipa/*.ipa --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  success "Successfully uploaded to App Store Connect!"

  if [ "$USE_FASTLANE" = true ]; then
    info "Pushing the App Store texts with Fastlane..."
    bundle exec fastlane ios metadata
    success "App Store texts pushed (not submitted for review)."
  fi
fi

#####################################
# Upload Android build and release notes (after the commit, like iOS)
# Fastlane when the Play JSON key is valid; otherwise (or on failure) manual via Finder, with the
# release notes on the clipboard. No manual fallback when Play refuses the signing key.
#####################################
if [ "$BUILT_ANDROID" = true ]; then
  if [ "$USE_ANDROID_FASTLANE" = true ]; then
    info "Uploading to Google Play (internal testing, draft) with Fastlane..."
    ANDROID_UPLOAD_LOG=$(mktemp)
    set +e
    bundle exec fastlane android upload 2>&1 | tee "$ANDROID_UPLOAD_LOG"
    ANDROID_UPLOAD_STATUS=${PIPESTATUS[0]}
    set -e
    if [ $ANDROID_UPLOAD_STATUS -eq 0 ]; then
      success "Successfully uploaded to Google Play!"
    elif grep -Eqi "signed with the wrong key|signed in debug mode" "$ANDROID_UPLOAD_LOG"; then
      # The same bundle would be refused by hand too.
      error "ERROR: Google Play refused the app bundle's signing key: android/key.properties does not"
      error "hold the upload key registered in Play Console (Test and release → App integrity)."
      error "Use the right keystore, or request an upload key reset there, then release again."
      exit 1
    else
      offer_manual_android_play_upload "Fastlane Play Store upload failed (exit $ANDROID_UPLOAD_STATUS)."
    fi
  elif [ "$USE_FASTLANE" = true ]; then
    # Fastlane used for iOS; Android is manual (user already agreed when the Play key was invalid).
    info "Opening the Android App Bundle in Finder for manual Play Console upload..."
    info "Upload it in Play Console → Testing → Internal testing (or your track) → Create new release."
    open_android_aab_in_finder
    success "AAB ready for manual upload to Google Play Console."
  fi
fi

run_release_hook post-upload

success "Release process completed successfully! 🎉"

exit
}
