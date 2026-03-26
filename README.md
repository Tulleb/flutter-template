# Flutter Template

Default configuration files to include into a new Flutter repository.

## Commands

Run these commands from your project directory (replace `$GIT_PATH/flutter/template` by the path leading to this repository):

```bash
# Dart
ln -s $GIT_PATH/flutter/template/analysis_options.yaml .

# Agents
mkdir agents
ln -s $GIT_PATH/flutter/template/AGENTS.md .
ln -s $GIT_PATH/flutter/template/agents/rules agents
cp $GIT_PATH/flutter/template/RULES.md .
```
