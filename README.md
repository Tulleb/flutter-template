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

Copy `.secret.local.example` to `.secret.local` (drop the `.example` suffix). Then generate the App Store Connect API key / `.p8` and the Google Play service-account JSON as described in that file, and fill in the empty values. Keep `.secret.local` and the key files outside version control; `scripts/release.sh` and the Fastlane lanes read them locally.
