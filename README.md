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

# Release secrets (never commit .secret.local)
cp $GIT_PATH/template/flutter/.secret.local.example .secret.local
```

## Release secrets

Copy `.secret.local.example` to `.secret.local` (drop the `.example` suffix). Then generate the App Store Connect API key / `.p8` and the Google Play service-account JSON, and fill in the empty values. Keep `.secret.local` and the key files outside version control; `scripts/release.sh` and the Fastlane lanes read them locally.

### Google Play service account key (`PLAY_STORE_JSON_KEY_PATH`)

Fastlane needs this key to upload builds and store listings to Google Play.

1. In the [Google Cloud Console](https://console.cloud.google.com), select or create a project.
2. Go to **APIs & Services → Library** and enable the **Google Play Android Developer API**.
3. Go to **IAM & Admin → Service Accounts → Create service account**, name it (e.g. `fastlane-play`) and skip the optional role step.
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
