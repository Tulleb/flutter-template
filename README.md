# Flutter Template

Default configuration files to include into a new Flutter repository.

## Commands

Run these commands from your project directory (replace `$GIT_PATH/template/flutter` by the path leading to this repository):

```bash
# Git (symbolic link not working for .gitignore)
cp $GIT_PATH/template/flutter/.gitignore .

# Dart
ln -s $GIT_PATH/template/flutter/analysis_options.yaml .

# Agents
mkdir agents
ln -s $GIT_PATH/template/flutter/AGENTS.md .
ln -s $GIT_PATH/template/flutter/agents/rules agents
cp $GIT_PATH/template/flutter/RULES.md .

# Scripts
mkdir scripts
ln -s $GIT_PATH/template/flutter/scripts/la-totale.sh scripts
ln -s $GIT_PATH/template/flutter/scripts/release.sh scripts
ln -s $GIT_PATH/template/flutter/scripts/write-changelog.py scripts
ln -s $GIT_PATH/template/flutter/scripts/changelog-format.md scripts

# Release secrets (never commit .secret.local)
cp $GIT_PATH/template/flutter/.secret.local.example .secret.local

# Fastlane (store texts, Google Play upload)
mkdir fastlane
ln -s $GIT_PATH/template/flutter/fastlane/Fastfile fastlane
cp $GIT_PATH/template/flutter/fastlane/Appfile.example fastlane/Appfile
cp $GIT_PATH/template/flutter/fastlane/changelog-context.example.md fastlane/changelog-context.md
cp $GIT_PATH/template/flutter/Gemfile.example Gemfile
bundle config set --local path vendor/bundle
bundle install

# Android upload key (never commit android/key.properties nor the keystore): fill it in from
# 1Password and drop upload-keystore.jks into android/app (see "Android upload key" below)
cp $GIT_PATH/template/flutter/android/key.properties.example android/key.properties
```

Then follow [Releases](#releases) to fill in the identifiers, keys and store locales.

## Releases

`scripts/release.sh` releases the app from your machine. It is shared by every app, Flutter or
native iOS, through the symlinks above, and finds the project root from its own location.

1. Bumps the version in `pubspec.yaml` when needed (patch, minor, major or build only). Store
   versions, tags and commits drop a `.0` patch (`1.3`, `1.3.1`); `pubspec.yaml` keeps `1.3.0`.
2. Writes the localized release notes with AI when the version has none yet (see
   [AI release notes](#ai-release-notes)), and checks every store text against its limit.
3. Runs `scripts/la-totale.sh`, then builds the Android app bundle and the iOS IPA.
4. Commits `Version <version>+<build>` (e.g. `Version 1.3+45`, `Version 1.3.1+46`) with the pubspec,
   release notes and iOS lockfiles, pushes it and tags it `<version>+<build>`.
5. Uploads the IPA to App Store Connect and pushes the App Store texts of that version (no review
   submission), then uploads the AAB with its notes as a draft on Google Play's internal testing
   track. Without a valid Play key, or when the upload fails, the AAB is shown in Finder to upload
   it by hand, and its release notes for every language are copied to the clipboard (and opened)
   to paste into Play Console at once. Without a valid Android upload key
   (`android/key.properties`, see [Android upload key](#android-upload-key)), the release stops
   before changing anything.

Fastlane steps run only when `fastlane/Fastfile` exists and Bundler is installed; without them,
the script still builds, tags and uploads the IPA, and opens the AAB in Finder. The full flow is
described for AI agents in `agents/rules/release.md`.

Before building, it warns when the working tree has uncommitted changes (they would ship without
being in the release commit). The release is atomic up to its commit: any exit before it (a
"no" to a prompt, an error, Ctrl-C) rolls back the version, release notes and lockfiles it
changed, keeping changes made before the release. Projects can add steps in
`scripts/release-hooks/pre-build.sh` (after the release notes, before the build; a failure stops the release) and
`scripts/release-hooks/post-upload.sh`, which receive `RELEASE_VERSION`, `RELEASE_BUILD` and
`RELEASE_TAG`; files they stage go into the release commit.

### Native iOS projects

A project with an `.xcodeproj` at its root and no `pubspec.yaml` is released as a native iOS app:

```bash
mkdir -p scripts fastlane
ln -s $GIT_PATH/template/flutter/scripts/release.sh scripts
ln -s $GIT_PATH/template/flutter/scripts/write-changelog.py scripts
ln -s $GIT_PATH/template/flutter/scripts/changelog-format.md scripts
cp $GIT_PATH/template/flutter/fastlane/changelog-context.example.md fastlane/changelog-context.md
```

- The version is `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in the `.xcodeproj`.
- The project keeps its own `fastlane/Fastfile` (signing is app-specific), with two lanes:
  `ios build` (archive and export the IPA) and `ios upload` (upload it with the App Store texts,
  without submitting for review). The release commits and tags between the two.
- App Store texts live in `fastlane/metadata/<locale>` (deliver's default), and feature names for
  the release notes come from the app's `<lang>.lproj/Localizable.strings`.
- `.secret.local` may name the App Store Connect key `APP_STORE_CONNECT_API_KEY_KEY_ID`,
  `APP_STORE_CONNECT_API_KEY_ISSUER_ID` and `APP_STORE_CONNECT_API_KEY_KEY_FILEPATH` instead.

Tags follow `<version>+<build>`; a project whose tags already use `<version>_<build>` keeps that
style (and its `Version X.Y (B)` commit messages).

### Fastlane

`fastlane/Fastfile` is shared through the symlink: fix or improve lanes here, in the template.
Per project:

1. Set the bundle id and Android `applicationId` in `fastlane/Appfile`.
2. Create one folder per store locale and the texts you want to version:
   - `fastlane/metadata/ios/<locale>/release_notes.txt` (App Store codes: `en-US`, `fr-FR`, `pt-BR`…)
   - `fastlane/metadata/android/<locale>/changelogs/default.txt` (Play codes: `en-US`, `fr-FR`,
     `iw-IL` for Hebrew, `es-419`…)
   - Optionally the full listings: `name.txt`, `subtitle.txt`, `description.txt`, `keywords.txt`…
     on iOS, `title.txt`, `short_description.txt`, `full_description.txt`, `images/…` on Android,
     and iOS screenshots in `fastlane/screenshots/ios/<locale>`. Files that don't exist are left
     untouched in the stores.
3. Commit `Gemfile`, `Gemfile.lock` and `fastlane/` (except the ignored reports).

Lanes (`bundle exec fastlane <lane>`): `validate_metadata`, `ios metadata`, `android metadata`,
`android upload`.

> The app must already exist in App Store Connect and in the Play Console, with a first bundle
> uploaded by hand to Play (e.g. to internal testing), before Fastlane can upload to it.

### Android upload key

Gradle signs the Android app bundle at build time with the app's upload key, and Google Play
(through Fastlane or by hand) refuses any other key. `scripts/release.sh` stops before changing
anything when `android/key.properties` is missing or wrong, and checks that the built bundle is
signed with it. Neither `android/key.properties` nor the keystore is ever committed.

1. Get the upload key from the app's 1Password item:
   - Download its `upload-keystore.jks` file into the `android/app` folder
     (`android/app/upload-keystore.jks`).
   - Copy `android/key.properties.example` from this template to `android/key.properties`, and fill
     in `storePassword`, `keyAlias` and `keyPassword` with the item's credentials. Keep
     `storeFile=upload-keystore.jks`: Gradle resolves it from the `android/app` folder.

   New app with no upload key yet: create it, then save the `.jks` file and its passwords in a new
   1Password item right away (the upload key can only be replaced through a reset request in
   Play Console):

   ```sh
   keytool -genkeypair -v -keystore android/app/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```

   With this default keystore type (PKCS12), `keyPassword` is the same as `storePassword`.

2. Load it in `android/app/build.gradle.kts` (once per project, committed):

   ```kotlin
   import java.util.Properties

   // Upload key for Google Play, see android/key.properties.example.
   val keystorePropertiesFile = rootProject.file("key.properties")
   val keystoreProperties = Properties().apply {
       if (keystorePropertiesFile.exists()) {
           keystorePropertiesFile.inputStream().use { load(it) }
       }
   }

   android {
       // ...
       signingConfigs {
           if (keystorePropertiesFile.exists()) {
               create("release") {
                   keyAlias = keystoreProperties.getProperty("keyAlias")
                   keyPassword = keystoreProperties.getProperty("keyPassword")
                   // Resolved from android/app, next to this file.
                   storeFile = file(keystoreProperties.getProperty("storeFile"))
                   storePassword = keystoreProperties.getProperty("storePassword")
               }
           }
       }

       buildTypes {
           release {
               // Without android/key.properties (never committed), the release build falls back
               // to the debug keys for `flutter run --release`; Google Play refuses them.
               signingConfig = if (keystorePropertiesFile.exists()) {
                   signingConfigs.getByName("release")
               } else {
                   logger.warn("android/key.properties not found: signing the release build with the debug keys.")
                   signingConfigs.getByName("debug")
               }
           }
       }
   }
   ```

### AI release notes

When `fastlane/release_notes_version.txt` doesn't name the version being released, or a store
locale has no notes, `scripts/release.sh` runs `scripts/write-changelog.py`:

1. OpenAI reads the commits since the last release tag (messages and trimmed diffs, without tests,
   tooling and generated files) and writes the reference notes (`en-US` when the project has it):
   a full App Store text and a Google Play one within 500 characters.
2. It localizes them into every store locale, naming screens and features with the app's own
   translations from the `.arb` files.
3. The notes are written to `fastlane/metadata`, the version to
   `fastlane/release_notes_version.txt`, and both go into the release commit.

Set `OPENAI_API_KEY` and `CHANGELOG_MODEL` in `.secret.local` (`CHANGELOG_MODEL` may sit in a
committed `.env` instead). Optional settings, in `.env` or `.secret.local`: `CHANGELOG_SKIP_PATHS`
(more path prefixes kept out of the diffs, comma-separated) and `CHANGELOG_EXTRA_REPOS` (related
repositories, e.g. `../backend`, whose commit messages over the same period count too).

To write the notes yourself, fill every locale and put the version in
`fastlane/release_notes_version.txt`: the release keeps them. Run the writer alone with
`RELEASE_VERSION=1.3 scripts/write-changelog.py`.

#### Changelog instructions

Every request to the model starts with instructions built from two Markdown files:

1. `scripts/changelog-format.md` (shared by every app, symlinked from this template): what goes in
   the notes, the section format, the Google Play version and the localization rules.
2. `fastlane/changelog-context.md` (optional, one per app): when the file exists, it is appended
   automatically after the shared rules, and wins where they disagree. Without it, the shared
   rules apply alone.

Use the project file for anything specific to the app: what it is and who it is for, its tone,
the exact names of its screens and plans, what to skip, an example changelog, or a whole different
format. Start from `fastlane/changelog-context.example.md`. Editing either file changes what the
next release writes; never put app-specific rules in the shared file.

No notes are written for a first release (no previous tag).

## Release secrets

Copy `.secret.local.example` to `.secret.local` (drop the `.example` suffix). Then generate the App Store Connect API key / `.p8`, the Google Play service-account JSON and an OpenAI API key (for the release notes), and fill in the empty values. Keep `.secret.local` and the key files outside version control; `scripts/release.sh` and the Fastlane lanes read them locally.

### Google Play service account key (`PLAY_STORE_JSON_KEY_PATH`)

Fastlane needs this key to upload builds and store listings to Google Play.

1. In the [Google Cloud Console](https://console.cloud.google.com), select or create a project.
2. Go to **APIs & Services → Library** and enable the **Google Play Android Developer API**.
3. Go to **IAM & Admin → Service Accounts → Create service account**, name it (e.g. `fastlane`) and skip the optional role step.
4. Open the new service account, go to **Keys → Add key → Create new key → JSON**. A `.json` file is downloaded.
5. In the [Google Play Console](https://play.google.com/console), go to **Users and permissions → Invite new users** and enter the service account's email (`…@….iam.gserviceaccount.com`).
6. Under **App permissions**, add the app and allow **View app information**, **Release to testing tracks** and **Manage store presence**, then send the invitation.
7. Move the key outside the repo and restrict its access:

   ```sh
   mkdir -p ~/.googleplay
   mv ~/Downloads/<key>.json ~/.googleplay/<app>-play.json
   chmod 600 ~/.googleplay/<app>-play.json
   ```

8. Add its absolute path to `.secret.local` (no `~`):

   ```
   PLAY_STORE_JSON_KEY_PATH=/Users/<you>/.googleplay/<app>-play.json
   ```

9. Check that it works (permissions can take a few minutes to apply):

   ```sh
   bundle exec fastlane run validate_play_store_json_key json_key:/Users/<you>/.googleplay/<app>-play.json
   ```

> The app must already exist in the Play Console, with a first bundle uploaded by hand (e.g. to internal testing), before Fastlane can upload to it.
