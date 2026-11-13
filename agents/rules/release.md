# Releases

App releases go through `scripts/release.sh`, a symlink to the shared Flutter template script
used by every app, Flutter or native iOS. Agents never run it (it builds, commits, pushes, tags
and uploads to the stores) unless explicitly asked, but must know what it does to prepare a
release and keep its inputs valid. Change it (and `scripts/write-changelog.py`,
`scripts/changelog-format.md`, the shared `fastlane/Fastfile`) in the template, never through a
copy in a project.

## Project types

- **Flutter** (`pubspec.yaml`): version `x.y.z+build` in `pubspec.yaml`; builds with
  `flutter build`, uploads the IPA with `xcrun altool` and the store texts and AAB with the shared
  Fastfile; optional web release (`lib/main_web.dart`) to Firebase Hosting.
- **Native iOS** (an `.xcodeproj` at the root): version in `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION`; the project's own `fastlane/Fastfile` provides `ios build` (archive
  and export the IPA) and `ios upload` (IPA and App Store texts, no review submission).

## What `scripts/release.sh` does

1. Asks what to release (mobile or web, the web option only in Flutter projects with
   `lib/main_web.dart`).
2. Loads `.secret.local` (never committed; see `.secret.local.example`) and checks the App Store
   Connect API key (`APP_STORE_CONNECT_API_KEY` / `APP_STORE_CONNECT_APP_ISSUER_ID` /
   `APP_STORE_CONNECT_API_KEY_PATH`, or the `APP_STORE_CONNECT_API_KEY_KEY_ID` / `_ISSUER_ID` /
   `_KEY_FILEPATH` naming).
3. Warns when the working tree has uncommitted changes, which would ship without being in the
   release commit.
4. Flutter: asks for the platforms (Android and iOS, iOS only, Android only). With Android,
   `android/key.properties` must hold a usable upload key (`android/app/upload-keystore.jks`,
   credentials from the app's 1Password item): otherwise the release stops before changing
   anything. After the Android build, it checks that the bundle is signed with that key, and
   stops before any commit otherwise.
5. Reads the version. Releases are tagged `<version>+<build>`, where a `.0` patch is dropped and
   any other patch kept (`1.3+45`, `1.3.1+46`): pubspec.yaml keeps `1.3.0` (Flutter needs x.y.z)
   while the stores, tag and commit use `1.3`. A project whose tags already use
   `<version>_<build>` (`7.3_15`, or `7.3` for build 1) keeps that style and its
   `Version 7.3 (15)` commit messages. When the tag exists, or the build number was already
   released, it offers a patch, minor, major or build-only bump, past the highest tagged build
   number, and writes it to the project.
6. When `fastlane/Fastfile` exists and Bundler is installed (required for native iOS): checks the
   Google Play key (`PLAY_STORE_JSON_KEY_PATH`, Flutter with Android), runs `bundle install`,
   writes the release notes with AI when they are missing (below), then runs
   `fastlane validate_metadata` when the Fastfile has it, so a store text over its limit fails
   before the builds.
7. Runs the project's `scripts/release-hooks/pre-build.sh` when it exists (after the notes, before
   the build; a failure stops the release; files it stages go into the release commit).
8. Builds. Flutter: `scripts/la-totale.sh` (clean, pub get, code generation, l10n, format,
   analyze…), then `flutter build appbundle` and `flutter build ipa` with `--build-name
   <version>` and `dart_defines.json` when present (and uploads the dSYMs to Crashlytics when the
   project uses `firebase_crashlytics`). Native iOS: `fastlane ios build`.
9. Commits `Version <version>+<build>` (or `Update release files for <tag>` without a bump) with
   the version file, the release notes (`fastlane/metadata`, `fastlane/release_notes_version.txt`)
   and the lockfiles, pushes it, then tags and pushes the release, before any upload.
10. Uploads. Native iOS: `fastlane ios upload`. Flutter: the IPA with `xcrun altool`, then
    `fastlane ios metadata` pushes the App Store texts for that version (never submits for
    review); `fastlane android upload` sends the AAB as a draft on the internal testing track
    with its notes. When the Play upload is not possible or fails (except when Play refuses the
    signing key, which stops the release), the AAB is shown in Finder for a manual Play Console
    upload, and the Play notes of every locale are copied to the clipboard and opened, in the
    Console's `<locale>…</locale>` format (`build/app/outputs/bundle/release/release-notes.txt`).
11. Runs the project's `scripts/release-hooks/post-upload.sh` when it exists.

Hooks receive `RELEASE_VERSION`, `RELEASE_BUILD` and `RELEASE_TAG`.

## Fastlane

- Fastlane runs through Bundler from the project root (`bundle exec fastlane <lane>`), with the
  gems in `vendor/bundle` (`bundle config set --local path vendor/bundle`).
- Flutter: `fastlane/Fastfile` is shared by every project (symlink to the Flutter template); only
  `fastlane/Appfile` (identifiers) and `Gemfile`/`Gemfile.lock` belong to the project. Lanes:
  `validate_metadata` (offline length checks), `ios metadata` (App Store texts and screenshots),
  `android metadata` (Play listing only), `android upload` (AAB + notes, internal draft).
- Native iOS: the project owns its Fastfile and must keep the `ios build` and `ios upload` lanes.
- Only the files that exist are pushed: a project versions just the release notes, or the full
  listings too (texts, Play images, iOS screenshots in `fastlane/screenshots/ios/<locale>`).
- Store locales are the folders of `fastlane/metadata/ios/<locale>` (Flutter) or
  `fastlane/metadata/<locale>` (native iOS), with App Store codes (e.g. `fr-FR`, `pt-BR`), and
  `fastlane/metadata/android/<locale>` with Play codes (e.g. `fr-FR`, `iw-IL` for Hebrew,
  `es-419`). Keep them in sync with the languages of each store listing.
- Limits: App Store release notes and descriptions 4000 characters, name and subtitle 30,
  keywords 100, promotional text 170; Play title 30, short description 80, full description
  4000, release notes 500.

## AI release notes

- `scripts/write-changelog.py` (shared) writes the notes of the version being released when
  `fastlane/release_notes_version.txt` does not name it or a locale has no notes: the commits
  since the last release tag (and the commit messages of `CHANGELOG_EXTRA_REPOS`) go to OpenAI
  (`OPENAI_API_KEY` in `.secret.local`, `CHANGELOG_MODEL` in `.secret.local` or `.env`) with the
  rules of `scripts/changelog-format.md` (shared) and the project's optional
  `fastlane/changelog-context.md`, then the notes are localized into every store locale with the
  app's own names (`.arb` files, or `Localizable.strings` in native iOS projects).
- Output: `<App Store folder>/<locale>/release_notes.txt` and
  `fastlane/metadata/android/<locale>/changelogs/default.txt` (a `changelogs/<build>.txt`
  overrides it for one build), plus the version in `fastlane/release_notes_version.txt`.
- To write the notes by hand instead, follow `scripts/changelog-format.md`, fill every locale and
  put the version in `fastlane/release_notes_version.txt`: the release then keeps them.
- The release shows the written notes and uploads them without asking; a build-only re-release
  keeps the same notes. Commit messages should therefore say what users get: they are what the
  model reads first.
- Project-specific guidance on the notes (app description, tone, names, paths to ignore) goes in
  `fastlane/changelog-context.md`, and extra skipped paths in `CHANGELOG_SKIP_PATHS`, never in
  the shared `scripts/changelog-format.md`.
