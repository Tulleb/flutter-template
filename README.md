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
```
