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

#####################################
# Release type selection
#####################################
info "What would you like to release?"
echo "1) Mobile App (default)"
echo "2) Web App"
echo "3) Exit"
read -p "Choose an option (1-3) [1]: " release_choice
release_choice=${release_choice:-1}

if [ "$release_choice" == "3" ]; then
  info "Exiting..."
  exit 0
fi

#####################################
# Check .env exists
#####################################
if [ ! -f .env ]; then
  error "ERROR: .env file not found."
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
# Load environment variables from .env file
#####################################
info "Loading environment variables from .env file..."
export $(grep -v '^#' .env | xargs)

#####################################
# Define the required ENV keys (Mobile only)
#####################################
REQUIRED_KEYS=(
  "APP_STORE_CONNECT_API_KEY"
  "APP_STORE_CONNECT_APP_ISSUER_ID"
)

#####################################
# Check that each key has a value
#####################################
info "Validating required environment variables..."
for KEY in "${REQUIRED_KEYS[@]}"; do
  VALUE=$(grep -E "^$KEY\s*=" .env | cut -d '=' -f2- | xargs)
  if [ -z "$VALUE" ]; then
    error "ERROR: Key '$KEY' is missing or empty in .env."
    exit 1
  fi
done
success "All required environment variables are present."

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
# Create and push a commit with the version bump
#####################################
if [ ! -z "$NEW_VERSION_FULL" ]; then
  info "Creating commit for version bump..."
  git add pubspec.yaml
  git commit -m "Version $NEW_VERSION_FULL"
  git push origin main
  success "Successfully pushed commit 'Version $NEW_VERSION_FULL' to remote!"
fi

#####################################
# Run La Totale
#####################################
info "Starting La Totale..."
./scripts/la-totale.sh
success "La Totale finished successfully."

#####################################
# Build for selected platforms
#####################################
for platform in "${PLATFORMS[@]}"; do
  info "Building for $platform..."

  case $platform in
    "android")
      info "Building Android app bundle..."
      flutter build appbundle --release --no-tree-shake-icons
      success "Android build finished successfully."
      info "Opening Android build directory..."
      open build/app/outputs/bundle/release
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

      # Build iOS app bundle
      flutter build ipa --release --no-tree-shake-icons
      success "iOS build finished successfully."
      info "Uploading to App Store Connect..."
      xcrun altool --upload-app --type ios -f build/ios/ipa/*.ipa --apiKey $APP_STORE_CONNECT_API_KEY --apiIssuer $APP_STORE_CONNECT_APP_ISSUER_ID
      success "Successfully uploaded to App Store Connect!"
      ;;
  esac
done

#####################################
# Create and push Git tag
#####################################
info "Preparing to tag release as '$NEW_VERSION_FULL'..."

# Create a new annotated tag
git tag -a "$NEW_VERSION_FULL" -m "Release $NEW_VERSION_FULL"

# Push the new tag to remote
git push origin "$NEW_VERSION_FULL"

success "Successfully pushed tag '$NEW_VERSION_FULL' to remote!"
success "Release process completed successfully! 🎉"
