#!/usr/bin/env python3
"""Write the localized release notes of RELEASE_VERSION with OpenAI.

Called by scripts/release.sh when fastlane/release_notes_version.txt does not hold the version
being released; can also be run by hand from the project root:
`RELEASE_VERSION=1.3 scripts/write-changelog.py`.

The model follows scripts/changelog-format.md (shared rules, next to this script in the Flutter
template), then the project's fastlane/changelog-context.md when it exists, in two passes:

1. It reads the commits since the last release tag of an earlier version (builds of the version
   being released are skipped, so a build-only bump still covers the whole version; messages,
   file stats and trimmed diffs, plus the commit messages of related repositories) and writes the reference notes (en-US when the
   project has it, else its first store locale): a full text for the App Store and a short one
   for Google Play, plus the exact screen, feature and setting names it used.
2. Those names are looked up in the app's translations (Flutter .arb files from l10n.yaml, or
   iOS <lang>.lproj/Localizable.strings), and the model localizes the reference notes into every
   other store locale with that name table.

Store locales are the folders of fastlane/metadata/ios/<locale> and
fastlane/metadata/android/<locale> (Flutter), or fastlane/metadata/<locale> (native iOS). The
notes go into <ios folder>/<locale>/release_notes.txt and android/<locale>/changelogs/default.txt,
and the version into fastlane/release_notes_version.txt. The files are left uncommitted:
release.sh adds them to its release commit.

Environment: RELEASE_VERSION (required), RELEASE_BUILD, RELEASE_TAG (the tag being released, left
out of the range), OPENAI_API_KEY and CHANGELOG_MODEL. Optional: CHANGELOG_SKIP_PATHS (more path
prefixes kept out of the diffs, comma-separated) and CHANGELOG_EXTRA_REPOS (paths of related
repositories, relative to the project, whose commit messages over the same period count too,
comma-separated). Each setting comes from the environment (release.sh loads .secret.local), else
from the project's .env.

Exit codes: 0 written, 1 failed, 3 nothing to write (no release tag of an earlier version or no store locale).
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API_URL = "https://api.openai.com/v1/responses"
IOS_MAX = 4000
ANDROID_MAX = 500
EXIT_SKIPPED = 3

# Paths whose changes never belong in the notes (changelog-format.md): kept out of the diffs.
SKIPPED_PATHS = ("scripts/", "fastlane/", "agents/", "test/", "integration_test/", "tool/",
                 ".github/", ".vscode/", "pubspec.lock", "ios/Podfile.lock",
                 "Pods/", "build/")
SKIPPED_SUFFIXES = (".g.dart", ".freezed.dart", ".lock", "Package.resolved", ".pbxproj",
                    ".xcscheme", ".xcworkspacedata")
DIFF_CHARS_PER_COMMIT = 15000
DIFF_CHARS_TOTAL = 350000
EXTRA_REPOS_CHARS_TOTAL = 20000

# Store locales whose language code differs from the .arb one (Google Play uses old codes).
LANGUAGE_ALIASES = {"iw": "he", "in": "id", "ji": "yi"}
REGIONAL_NOTES = {
    "fr-CA": "Canadian French (Québec usage), not a copy of fr-FR.",
    "es-MX": "Mexican Spanish, not a copy of es-ES.",
    "es-419": "Latin American Spanish, not a copy of es-ES.",
    "es-US": "US Spanish (Latin American usage), not a copy of es-ES.",
    "pt-BR": "Brazilian Portuguese.",
    "pt-PT": "European Portuguese (Portugal usage), not a copy of pt-BR.",
    "en-GB": "British English spelling.",
    "zh-TW": "Traditional Chinese (Taiwan).",
    "zh-HK": "Traditional Chinese (Hong Kong).",
}
LOCALE_PATTERN = re.compile(r"[a-z]{2,3}(-[A-Za-z0-9]+)*")


def fail(message):
    print(f"ERROR: {message}")
    sys.exit(1)


def skip(message):
    print(message)
    sys.exit(EXIT_SKIPPED)


def run_git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                          text=True).stdout


try:
    REPO = Path(run_git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
except subprocess.CalledProcessError:
    fail("Run this script from inside the project's git repository.")
METADATA = REPO / "fastlane" / "metadata"
# Flutter projects keep the App Store texts in fastlane/metadata/ios (next to android); native iOS
# projects in fastlane/metadata itself.
IOS_METADATA = METADATA / "ios" if (REPO / "pubspec.yaml").is_file() else METADATA
RELEASE_TAG_PATTERN = re.compile(r"\d+\.\d+(\.\d+)?([+_]\d+)?")


def git(*args):
    return run_git(REPO, *args)


def env_setting(name):
    """A variable from the environment, else from the project's .env (KEY=value lines)."""
    if os.environ.get(name):
        return os.environ[name]
    env_file = REPO / ".env"
    if env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            if key.strip() == name and not line.lstrip().startswith("#"):
                return value.strip().strip("\"'")
    return ""


def store_locales(store):
    folder = IOS_METADATA if store == "ios" else METADATA / "android"
    if store == "android" and IOS_METADATA == METADATA:
        return []
    if not folder.is_dir():
        return []
    return sorted(p.name for p in folder.iterdir()
                  if p.is_dir() and LOCALE_PATTERN.fullmatch(p.name))


def same_version(a, b):
    """True when two X.Y[.Z] versions are equal, a ".0" patch ignored (7.1.0 is 7.1)."""
    return re.sub(r"^(\d+\.\d+)\.0$", r"\1", a) == re.sub(r"^(\d+\.\d+)\.0$", r"\1", b)


def previous_tag(version, build):
    """The latest release tag (1.3+45, 7.3_15 or 7.3) of an earlier version than the one being
    released: on a build-only bump (1.3+46 after 1.3+45), the notes still cover every change since
    the previous version, not just since the last build."""
    current = {os.environ.get("RELEASE_TAG", ""), f"{version}+{build}", f"{version}_{build}"}
    for tag in git("tag", "--sort=-creatordate").split():
        if not RELEASE_TAG_PATTERN.fullmatch(tag) or tag in current:
            continue
        if not same_version(re.split(r"[+_]", tag)[0], version):
            return tag
    return None


def setting_list(name):
    return [item.strip() for item in env_setting(name).split(",") if item.strip()]


def changelog_rules():
    shared = Path(__file__).resolve().parent / "changelog-format.md"
    if not shared.is_file():
        shared = REPO / "scripts" / "changelog-format.md"
    if not shared.is_file():
        fail("scripts/changelog-format.md is missing.")
    rules = shared.read_text(encoding="utf-8").strip()
    context = REPO / "fastlane" / "changelog-context.md"
    if context.is_file():
        rules += ("\n\n# Project context (wins over the rules above)\n\n"
                  + context.read_text(encoding="utf-8").strip())
    return rules


def skipped(path, extra=()):
    return path.startswith(SKIPPED_PATHS + tuple(extra)) or path.endswith(SKIPPED_SUFFIXES) \
        or "/generated/" in path or "app_localizations" in path


def commits_digest(tag):
    shas = git("rev-list", "--reverse", "--no-merges", f"{tag}..HEAD").split()
    if not shas:
        fail(f"No commits since {tag}: write the notes by hand or keep the previous ones.")
    extra_skips = setting_list("CHANGELOG_SKIP_PATHS")
    parts, total = [], 0
    for sha in shas:
        message = git("show", "-s", "--format=%h %s%n%n%b", sha).strip()
        stat = git("show", "--stat=120", "--format=", sha).strip()
        paths = [p for p in git("show", "--name-only", "--format=", sha).splitlines()
                 if p and not skipped(p, extra_skips)]
        diff = git("show", "--format=", "--unified=1", sha, "--", *paths) if paths else ""
        # Only changed lines and file headers: enough to see what each commit really does.
        diff = "\n".join(line for line in diff.splitlines()
                         if line.startswith(("+", "-", "diff --git"))
                         and not line.startswith(("+++", "---")))
        budget = min(DIFF_CHARS_PER_COMMIT, max(0, DIFF_CHARS_TOTAL - total))
        if len(diff) > budget:
            diff = diff[:budget] + "\n[diff truncated]"
        total += len(diff)
        parts.append(f"=== commit {message}\n{stat}\n{diff}")
    return "\n\n".join(parts)


def extra_repos_commits(tag):
    """Commit messages of the related repositories (CHANGELOG_EXTRA_REPOS) since `tag` was made."""
    since = git("log", "-1", "--format=%cI", tag).strip()
    sections = []
    for path in setting_list("CHANGELOG_EXTRA_REPOS"):
        repo = (REPO / path).resolve()
        if not (repo / ".git").exists():
            print(f"Skipping {path} (CHANGELOG_EXTRA_REPOS): not a git checkout.")
            continue
        result = subprocess.run(
            ["git", "log", "--reverse", "--no-merges", f"--since={since}", "--format=- %s%n%b"],
            cwd=repo, check=False, capture_output=True, text=True)
        lines = [line for line in result.stdout.splitlines()
                 if line.strip() and not line.lower().startswith("co-authored-by:")]
        if result.returncode == 0 and lines:
            sections.append(f"--- {repo.name}\n" + "\n".join(lines))
    return "\n\n".join(sections)[:EXTRA_REPOS_CHARS_TOTAL]


def arb_files():
    """{arb locale such as "pt_BR": path}, from l10n.yaml (arb-dir, template-arb-file)."""
    arb_dir, template = "lib/l10n", "app_en.arb"
    l10n = REPO / "l10n.yaml"
    if l10n.is_file():
        for line in l10n.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition(":")
            if key.strip() == "arb-dir":
                arb_dir = value.strip().strip("\"'")
            elif key.strip() == "template-arb-file":
                template = value.strip().strip("\"'")
    # app_en.arb -> "app_"; the locale part may carry a script or region (app_pt_BR.arb).
    match = re.fullmatch(r"(.*?_)?[a-z]{2,3}(?:_[A-Z][A-Za-z0-9]*)*\.arb", template)
    prefix = (match.group(1) or "") if match else "app_"
    files = {}
    for path in (REPO / arb_dir).glob(f"{prefix}*.arb"):
        files[path.stem[len(prefix):]] = path
    return files


def arb_for(locale, files):
    language, _, region = locale.partition("-")
    language = LANGUAGE_ALIASES.get(language, language)
    for key in (f"{language}_{region}", f"{language}_{region.upper()}", language):
        if key in files:
            return files[key]
    return None


def read_arb(path):
    if path is None:
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return {k: v for k, v in data.items() if not k.startswith("@") and isinstance(v, str)}


STRINGS_ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)


def strings_folders():
    """{lproj language such as "pt-BR": [Localizable.strings paths]} of a native iOS app."""
    folders = {}
    for path in REPO.glob("**/*.lproj/Localizable.strings"):
        relative = path.relative_to(REPO).as_posix()
        if relative.startswith(("build/", "Pods/", "DerivedData/")) or "/build/" in relative:
            continue
        folders.setdefault(path.parent.name[:-len(".lproj")], []).append(path)
    return folders


def strings_for(locale, folders):
    language, _, region = locale.partition("-")
    language = LANGUAGE_ALIASES.get(language, language)
    for key in (locale, f"{language}-{region}", f"{language}_{region}", language,
                "Base" if language == "en" else None):
        if key and key in folders:
            table = {}
            for path in folders[key]:
                try:
                    text = path.read_text(encoding="utf-8")
                except UnicodeDecodeError:
                    text = path.read_text(encoding="utf-16")
                for match in STRINGS_ENTRY.finditer(text):
                    table.setdefault(match.group(1), match.group(2))
            return table
    return {}


def translations_for(locale):
    """The app's strings in a store locale: .arb (Flutter) or Localizable.strings (native iOS)."""
    if (REPO / "pubspec.yaml").is_file():
        return read_arb(arb_for(locale, ARB_FILES))
    return strings_for(locale, STRINGS_FOLDERS)


def name_table(names, reference_strings, target_strings):
    """The target's translation of each name used in the reference notes, through the string keys
    (iOS keys are often the English text itself)."""
    keys = {value: key for key, value in reference_strings.items()}
    table = {}
    for name in names:
        key = keys.get(name, name)
        if key in target_strings:
            table[name] = target_strings[key]
    return table


def ask(model, api_key, instructions, prompt, schema_name, schema):
    body = json.dumps({
        "model": model,
        "instructions": instructions,
        "input": prompt,
        "text": {"format": {"type": "json_schema", "name": schema_name, "strict": True,
                            "schema": schema}},
    }).encode()
    request = urllib.request.Request(API_URL, data=body, method="POST", headers={
        "Authorization": f"Bearer {api_key}", "Content-Type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=600) as response:
                payload = json.load(response)
            break
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")[:500]
            if (error.code < 500 and error.code != 429) or attempt == 2:
                fail(f"OpenAI request failed ({error.code}): {detail}")
        except (urllib.error.URLError, TimeoutError) as error:
            if attempt == 2:
                fail(f"OpenAI request failed: {error}")
        time.sleep(5 * (attempt + 1))
    texts = [part["text"] for item in payload.get("output", []) if item.get("type") == "message"
             for part in item.get("content", []) if part.get("type") == "output_text"]
    if not texts:
        fail(f"OpenAI returned no text (status {payload.get('status')}).")
    return json.loads("".join(texts))


def object_schema(properties):
    return {"type": "object", "additionalProperties": False, "required": list(properties),
            "properties": properties}


def emoji_in(text):
    """Emoji and pictographs, which the stores may refuse in release notes."""
    return sorted({ch for ch in text
                   if 0x1F000 <= ord(ch) <= 0x1FAFF or 0x2600 <= ord(ch) <= 0x27BF
                   or 0x2B00 <= ord(ch) <= 0x2BFF or ord(ch) in (0x200D, 0xFE0F)})


def tidy(text):
    """Trimmed lines, exactly one empty line between "•" sections, no BOM."""
    out = []
    for line in (l.rstrip() for l in text.lstrip("﻿").strip().splitlines()):
        if not line:
            continue
        if line.startswith("•") and out:
            out.append("")
        out.append(line)
    return "\n".join(out)


def locale_line(locale, names):
    note = f" — {REGIONAL_NOTES[locale]}" if locale in REGIONAL_NOTES else ""
    return f"{locale}{note}\nName table: {json.dumps(names, ensure_ascii=False)}"


ARB_FILES = {}
STRINGS_FOLDERS = {}


def main():
    global ARB_FILES, STRINGS_FOLDERS
    if (REPO / "pubspec.yaml").is_file():
        ARB_FILES = arb_files()
    else:
        STRINGS_FOLDERS = strings_folders()
    version = os.environ.get("RELEASE_VERSION") or fail("RELEASE_VERSION is required.")
    build = os.environ.get("RELEASE_BUILD", "")

    ios, android = store_locales("ios"), store_locales("android")
    if not ios and not android:
        skip("No store locale in fastlane/metadata/ios or fastlane/metadata/android: no notes to write.")
    tag = previous_tag(version, build)
    if tag is None:
        skip("No release tag of an earlier version: first release, no notes to write.")

    api_key = env_setting("OPENAI_API_KEY") or fail(
        "OPENAI_API_KEY is missing: add it to .secret.local to write the notes automatically.")
    model = env_setting("CHANGELOG_MODEL") or fail(
        "CHANGELOG_MODEL is missing: add it to .secret.local (or .env).")

    all_locales = sorted(set(ios) | set(android))
    reference = "en-US" if "en-US" in all_locales else (ios or android)[0]
    print(f"Writing the {version} release notes with {model} (commits {tag}..HEAD, "
          f"reference {reference})...")
    instructions = ("You write the store release notes of a mobile app. Follow these rules "
                    "exactly:\n\n" + changelog_rules())

    # Pass 1: reference notes from the commits.
    fields = {"names": {"type": "array", "items": {"type": "string"}}}
    if ios:
        fields["text"] = {"type": "string"}
    if android:
        fields["short"] = {"type": "string"}
    wanted = []
    if ios:
        wanted.append(f"`text`: the App Store notes, at most {IOS_MAX} characters")
    if android:
        wanted.append(f"`short`: the Google Play notes, at most {ANDROID_MAX} characters "
                      "including spaces and line breaks (keep the most notable items)")
    extra = extra_repos_commits(tag)
    extra_section = (
        "\n\n=== Commits of related repositories (e.g. the backend) over the same period, "
        "messages only. Keep only what a user notices in the app, fold it into the matching "
        "section, and never name a server, function, provider or model.\n" + extra) if extra else ""
    first = ask(model, api_key, instructions, (
        f"Write the {reference} release notes of version {version}. Return "
        + "; ".join(wanted) + ". Also list in `names` every screen, feature, setting and button "
        f"name you used, spelled exactly as the app shows it in {reference}.\n\n"
        f"Here are the commits since the last release ({tag}), with their file stats and changed "
        "lines (tests, tooling, fastlane and generated files are left out). Check each entry "
        "against the diff, not just the commit title, and keep user-facing changes only.\n\n"
        + commits_digest(tag) + extra_section),
        "reference_notes", object_schema(fields))

    notes = {}  # (store, locale) -> text
    if ios:
        notes[("ios", reference)] = first["text"]
    if android:
        notes[("android", reference)] = first["short"]

    # Pass 2: every other locale, with the app's own translation of each name.
    ios_others = [l for l in ios if l != reference]
    android_others = [l for l in android if l != reference]
    if ios_others or android_others:
        reference_strings = translations_for(reference)
        tables = {l: name_table(first["names"], reference_strings, translations_for(l))
                  for l in set(ios_others) | set(android_others)}
        properties, sections = {}, []
        if ios_others:
            properties["ios"] = object_schema({l: {"type": "string"} for l in ios_others})
            sections.append(
                f"`ios`: the App Store notes (at most {IOS_MAX} characters each), from:\n"
                + first["text"] + "\n\nfor these locales:\n\n"
                + "\n\n".join(locale_line(l, tables[l]) for l in ios_others))
        if android_others:
            properties["android"] = object_schema({l: {"type": "string"} for l in android_others})
            sections.append(
                f"`android`: the Google Play notes (at most {ANDROID_MAX} characters each "
                "including spaces and line breaks: shorten when a language needs more room), "
                "from:\n" + first["short"] + "\n\nfor these locales:\n\n"
                + "\n\n".join(locale_line(l, tables[l]) for l in android_others))
        localized = ask(model, api_key, instructions, (
            f"Localize these {reference} release notes into each locale below as natural store "
            "copy in that language, section titles included, keeping the same structure: \"•\" "
            "sections separated by one empty line, \"-\" items without final punctuation, \"&\" "
            "rather than \"and\", no header, closing line or emoji. Name screens, features and "
            "settings exactly as the app shows them in that language: use the name table given "
            "for each locale (capitalized as shown, never in all caps); a name missing from it is "
            "translated naturally. Adapt regional variants instead of copying them.\n\n"
            + "\n\n".join(sections)),
            "localized_notes", object_schema(properties))
        for store in ("ios", "android"):
            for locale, text in localized.get(store, {}).items():
                notes[(store, locale)] = text

    notes = {key: tidy(text) for key, text in notes.items()}

    # Texts over the limit get one shortening pass.
    limit = {"ios": IOS_MAX, "android": ANDROID_MAX}
    too_long = {f"{s}:{l}": t for (s, l), t in notes.items() if len(t) > limit[s]}
    if too_long:
        print(f"Shortening {len(too_long)} text(s) over the store limits...")
        shorter = ask(model, api_key, instructions, (
            "Shorten each of these release notes, keeping its language and exact format and the "
            "most notable items, to fit its limit in characters (spaces and line breaks "
            "included):\n\n" + "\n\n".join(
                f"{key} (limit {limit[key.split(':')[0]] - 20}):\n{text}"
                for key, text in too_long.items())),
            "shortened_notes", object_schema({k: {"type": "string"} for k in too_long}))
        for key, text in shorter.items():
            store, locale = key.split(":", 1)
            notes[(store, locale)] = tidy(text)

    for (store, locale), text in notes.items():
        if not text:
            fail(f"The {store} {locale} notes written by {model} are empty.")
        if emoji_in(text):
            fail(f"The {store} {locale} notes written by {model} have emoji: {''.join(emoji_in(text))}")
        if len(text) > limit[store]:
            fail(f"The {store} {locale} notes written by {model} are over {limit[store]} characters.")

    for (store, locale), text in notes.items():
        path = (IOS_METADATA / locale / "release_notes.txt" if store == "ios"
                else METADATA / "android" / locale / "changelogs" / "default.txt")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text + "\n", encoding="utf-8")
    # Which version these notes are for: release.sh writes them again when it differs.
    (REPO / "fastlane" / "release_notes_version.txt").write_text(version + "\n", encoding="utf-8")

    for store in ("ios", "android"):
        if (store, reference) in notes:
            print(f"\n----- {version} {store} notes ({reference}) -----\n"
                  f"{notes[(store, reference)]}")
    print("-----------------------------------------")


if __name__ == "__main__":
    main()
