# Release changelog format

Every release ships its changelog, localized into every store locale of the project:

- App Store "What's New": `fastlane/metadata/ios/<locale>/release_notes.txt` (4000 characters).
- Google Play release notes: `fastlane/metadata/android/<locale>/changelogs/default.txt`
  (500 characters).

`scripts/write-changelog.py` sends this whole file to the model as its instructions, followed by
the project's own `fastlane/changelog-context.md` when there is one (what the app is, who it is
for, feature names, paths to ignore, a different format). Editing them changes what the release
script writes; the project file wins when they disagree.

## Content

- Range: the commits since the last release tag (`X.Y+B` or `X.Y.Z+B`, written by
  `scripts/release.sh`). Keep user-facing changes only; skip tests, tooling, CI, release scripts,
  fastlane, agent rules, dependency bumps, refactors and version bumps. Check each entry against
  the diff and the new strings, not just the commit title.
- Mark a feature as paid (Pro, Premium…) only when the code gates it.
- Never name a library, server, service, provider or AI model, nor any internal code name.
- Version: the version being released is not written in the notes. A build-only re-release keeps
  the same notes.

## Reference format

The reference locale (en-US when the project has it) is written in this exact format:

```text
• Home:
- Added a search bar to find your items faster

• Settings:
- New dark theme

• Misc:
- The app no longer freezes when the network drops
- More minor fixes & improvements
```

- Only the sections: no header, version line, intro or closing line.
- One `• Section:` per screen or feature, named as the app shows it.
- Misc is always the last section, and every changelog has one: its last item is always
  "More minor fixes & improvements" (localized), even when it is the only item.
- One empty line between sections, none inside a section.
- Short `-` items without final punctuation.
- "&" rather than "and".
- No emoji anywhere: plain text, with `•` and `-` as the only bullets.

## Google Play version

Google Play allows only 500 characters: the Play notes keep the same format and the most notable
items, merging or dropping minor ones, and still end with the Misc section.

## Localization

- Localize everything, section titles included, as natural store copy in each language.
- Name screens, features and settings exactly as the app shows them in that language (the
  project's `.arb` strings), capitalized as the app shows them, never in all caps.
- Adapt regional variants (fr-CA, es-MX, pt-BR vs. pt-PT…) instead of copying them blindly.

## Files

- UTF-8 without BOM, within the store limits above.
- `fastlane/release_notes_version.txt` holds the version the notes were written for (e.g. `1.3`):
  the release writes the notes again whenever it does not match the version being released.
