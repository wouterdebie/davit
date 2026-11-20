#!/bin/bash
# Keeps the String Catalog in sync with the UI strings in the sources.
#
# Usage:
#   scripts/localize.sh            update Localization/Localizable.xcstrings
#   scripts/localize.sh --check    verify only; exit 1 on drift or a bad catalog
#   scripts/localize.sh --strict   --check, plus exit 1 on untranslated strings
#
# There is no SwiftPM resource: the app is the package's executable, so SwiftUI
# looks up the compiled catalog in Bundle.main. bundle.sh compiles it into
# Contents/Resources/<lang>.lproj.
set -euo pipefail
cd "$(dirname "$0")/.."

# Every UI string must be translated into these languages. English is the
# source language; add a code here, run the script, then fill in the catalog.
LANGUAGES=(uk)

CATALOG="Localization/Localizable.xcstrings"
BUNDLE="scripts/bundle.sh"
SOURCES="Sources/ContainerStack"
# A separate scratch path: -emit-localized-strings changes every module's
# compiler command, and sharing .build would invalidate the normal build cache
# (a full dependency rebuild) on every run.
SCRATCH=".build/l10n"
STRINGS_DIR="$SCRATCH/LocalizedStrings"
EXTRACT_LIST="$SCRATCH/stringsdata-files.txt"
EXTRACT_KEYS="$SCRATCH/extracted-keys.json"

MODE=sync
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  --strict) MODE=strict ;;
  *) echo "usage: scripts/localize.sh [--check|--strict]" >&2; exit 2 ;;
esac

if ! command -v xcrun >/dev/null 2>&1 \
   || ! XCSTRINGSTOOL="$(xcrun --find xcstringstool 2>/dev/null)"; then
  echo "error: xcstringstool not found — install Xcode (or run xcode-select)" >&2
  exit 1
fi

if [ "$MODE" != sync ] && [ ! -f "$CATALOG" ]; then
  echo "error: $CATALOG is missing; run scripts/localize.sh" >&2
  exit 1
fi

WORK="$(mktemp -d -t davit-localize)"
trap 'rm -rf "$WORK"' EXIT

# JSON handling (stale removal, specifier checks) lives in one small helper.
cat > "$WORK/localize.py" <<'PY'
import json
import os
import re
import sys


def die(message, code=1):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as error:
        die(f"{path}: invalid JSON: {error}")


def collect(strings_dir, sources_dir, list_path, keys_path):
    """List only the .stringsdata produced from our sources.

    SwiftPM applies -Xswiftc to every module, so dependencies write
    .stringsdata files too; worse, a file name like Models.swift can overwrite
    ours. Every source file must therefore have a .stringsdata that records its
    own path, or we refuse to sync a catalog that would silently lose strings.
    """
    sources = []
    for root, _, files in os.walk(sources_dir):
        for name in files:
            if name.endswith(".swift"):
                sources.append(os.path.join(root, name))

    by_name = {}
    data_files = []
    keys = set()
    for source in sorted(sources):
        name = os.path.basename(source)[:-len(".swift")]
        if name in by_name:
            die(f"{source} and {by_name[name]} share a file name; "
                "their extraction output would collide")
        by_name[name] = source

        data = os.path.join(strings_dir, name + ".stringsdata")
        if not os.path.exists(data):
            die(f"missing {data} for {source}", 3)
        document = load(data)
        recorded = document.get("source")
        if not recorded or os.path.abspath(recorded) != os.path.abspath(source):
            die(f"{data} describes {recorded}, not {source} — another module "
                "overwrote our extraction output")

        data_files.append(data)
        for entries in document.get("tables", {}).values():
            for entry in entries:
                keys.add(entry["key"])

    with open(list_path, "w", encoding="utf-8") as handle:
        handle.write("".join(path + "\n" for path in data_files))
    with open(keys_path, "w", encoding="utf-8") as handle:
        json.dump(sorted(keys), handle, ensure_ascii=False)


def prune(catalog_path, keys_path):
    """Drop keys that no longer occur in the code before syncing.

    xcstringstool removes keys it considers stale in some versions and only
    marks them in others; deleting them here makes the result independent of
    that behavior.
    """
    document = load(catalog_path)
    if document is None:
        die(f"{catalog_path} is missing")
    keys = set(load(keys_path) or [])
    strings = document.get("strings")
    if not isinstance(strings, dict):
        die(f"{catalog_path}: \"strings\" is missing or not a dictionary")

    removed = [key for key in strings if key not in keys]
    for key in removed:
        del strings[key]
    if removed:
        with open(catalog_path, "w", encoding="utf-8") as handle:
            json.dump(document, handle, ensure_ascii=False, indent=2, sort_keys=True)


# printf-style specifiers, including positional forms and the literal "%%".
SPEC_RE = re.compile(
    r"%(?:(\d+)\$)?([-+ 0#']*)(\*|\d+)?(?:\.(\*|\d+))?"
    r"(hh|h|ll|l|q|L|z|t|j)?([diouxXeEfFgGaAcCsSp@%])"
)
PLURAL_FORMS = {"uk": ("one", "few", "many", "other")}


def format_tokens(text):
    tokens = []
    position = 1
    for match in SPEC_RE.finditer(text):
        conversion = match.group(6)
        if conversion == "%":
            tokens.append((0, "%"))
            continue
        if match.group(1):
            tokens.append((int(match.group(1)), conversion))
        else:
            tokens.append((position, conversion))
            position += 1
    return sorted(tokens)


def describe(tokens):
    return "[" + ", ".join(
        "%%" if position == 0 else f"{position}:%{conversion}"
        for position, conversion in tokens
    ) + "]"


def string_units(node, path=()):
    """Every stringUnit below node, with its location for error messages."""
    units = []
    if isinstance(node, dict):
        if "stringUnit" in node:
            units.append((path, node["stringUnit"] or {}))
        for key, value in node.items():
            if key != "stringUnit":
                units.extend(string_units(value, path + (key,)))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            units.extend(string_units(value, path + (str(index),)))
    return units


def validate_format(catalog_path, document):
    problems = 0
    for key, entry in sorted(document.get("strings", {}).items()):
        expected = format_tokens(key)
        for language, localization in sorted((entry.get("localizations") or {}).items()):
            for path, unit in string_units(localization):
                actual = format_tokens(unit.get("value") or "")
                if actual != expected:
                    where = ".".join(path) or "stringUnit"
                    print(
                        f"error: {catalog_path}: format specifiers differ for "
                        f"\"{key}\" ({language}, {where}): expected "
                        f"{describe(expected)}, got {describe(actual)}",
                        file=sys.stderr,
                    )
                    problems += 1
    return problems


def is_translated(entry, language):
    localization = (entry.get("localizations") or {}).get(language)
    if not localization:
        return False
    plural = (localization.get("variations") or {}).get("plural")
    if plural is not None:
        for form in PLURAL_FORMS.get(language, ("one", "other")):
            unit = plural.get(form)
            if not unit:
                return False
            if not any(unit_.get("state") == "translated"
                       for _, unit_ in string_units(unit)):
                return False
        return True
    units = string_units(localization)
    return bool(units) and all(unit.get("state") == "translated" for _, unit in units)


def coverage(document, languages):
    strings = document.get("strings", {})
    return {
        language: sum(1 for entry in strings.values() if is_translated(entry, language))
        for language in languages
    }


def bundle_languages(bundle_path):
    """The CFBundleLocalizations array from bundle.sh, or None if it is gone."""
    try:
        with open(bundle_path, encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        die(f"{bundle_path} is missing")
    match = re.search(r"<key>CFBundleLocalizations</key>\s*<array>(.*?)</array>",
                      text, re.DOTALL)
    if not match:
        return None
    return re.findall(r"<string>([^<]+)</string>", match.group(1))


def validate_bundle_languages(bundle_path, languages):
    """bundle.sh and LANGUAGES must agree, or macOS never offers the language."""
    declared = bundle_languages(bundle_path)
    if declared is None:
        print(f"error: {bundle_path} has no CFBundleLocalizations array",
              file=sys.stderr)
        return 1
    bundled = sorted(language for language in declared if language != "en")
    expected = sorted(languages)
    if bundled != expected:
        print(f"error: languages disagree: {bundle_path} declares "
              f"[{', '.join(bundled) or 'none'}] (without en) but "
              f"scripts/localize.sh has LANGUAGES=[{', '.join(expected)}]; "
              "add the language to both", file=sys.stderr)
        return 1
    return 0


def finish(mode, expected_path, actual_path, languages, bundle_path):
    expected = load(expected_path)
    actual = load(actual_path)
    expected_strings = expected.get("strings", {})
    actual_strings = (actual or {}).get("strings", {})

    added = sorted(set(expected_strings) - set(actual_strings))
    stale = sorted(set(actual_strings) - set(expected_strings))
    errors = 0

    if mode != "sync":
        errors += validate_bundle_languages(bundle_path, languages)
        if actual is None:
            print(f"error: {actual_path} is missing; run scripts/localize.sh",
                  file=sys.stderr)
            errors += 1
        else:
            for key in added:
                print(f"error: new key is not in the catalog: \"{key}\"",
                      file=sys.stderr)
                errors += 1
            for key in stale:
                print(f"error: stale key is still in the catalog: \"{key}\"",
                      file=sys.stderr)
                errors += 1
            if not added and not stale:
                with open(expected_path, "rb") as check, open(actual_path, "rb") as current:
                    if check.read() != current.read():
                        print(f"error: {actual_path} is out of date (comments or "
                              "source strings changed); run scripts/localize.sh",
                              file=sys.stderr)
                        errors += 1

    checked = expected if mode == "sync" else actual
    if checked is not None:
        errors += validate_format(expected_path if mode == "sync" else actual_path,
                                  checked)

    if mode == "sync":
        changed = True
        if actual is not None:
            with open(expected_path, "rb") as check, open(actual_path, "rb") as current:
                changed = check.read() != current.read()
        if changed:
            os.makedirs(os.path.dirname(actual_path) or ".", exist_ok=True)
            with open(actual_path, "wb") as out, open(expected_path, "rb") as src:
                out.write(src.read())
        report = expected
    else:
        report = actual or {"strings": {}}

    total = len(report.get("strings", {}))
    print(f"localization: {total} keys, {len(added)} added, {len(stale)} removed")
    translated = coverage(report, languages)
    for language in languages:
        print(f"  {language}: {translated[language]}/{total} translated")
    if mode == "strict":
        for language in languages:
            count = translated[language]
            if count < total:
                print(f"error: {total - count} strings are not translated into {language}",
                      file=sys.stderr)
                errors += 1

    sys.exit(1 if errors else 0)


def main():
    command = sys.argv[1]
    if command == "collect":
        collect(*sys.argv[2:6])
    elif command == "checkjson":
        load(sys.argv[2])
    elif command == "prune":
        prune(*sys.argv[2:4])
    elif command == "finish":
        mode = sys.argv[2]
        finish(mode, sys.argv[3], sys.argv[4], sys.argv[5].split(","), sys.argv[6])
    else:
        die(f"unknown command {command}")


if __name__ == "__main__":
    main()
PY

extract_strings() {
  local log rc=0
  log="$(mktemp -t davit-localize-build)"
  mkdir -p "$STRINGS_DIR"
  if ! swift build --scratch-path "$SCRATCH" \
      -Xswiftc -emit-localized-strings \
      -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$STRINGS_DIR" \
      >"$log" 2>&1; then
    echo "error: string extraction build failed:" >&2
    tail -40 "$log" >&2
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
  python3 "$WORK/localize.py" collect "$STRINGS_DIR" "$SOURCES" \
    "$EXTRACT_LIST" "$EXTRACT_KEYS"
}

if [ -f "$CATALOG" ]; then
  python3 "$WORK/localize.py" checkjson "$CATALOG"
fi

echo "==> Extracting UI strings from $SOURCES" >&2
extract_strings && rc=0 || rc=$?
# The incremental build does not regenerate output that was deleted from the
# scratch directory, so start over in that case.
if [ "$rc" -eq 3 ]; then
  echo "==> Extraction output is incomplete; rebuilding from scratch" >&2
  rm -rf "$SCRATCH"
  extract_strings || exit 1
elif [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

TMP_CATALOG="$WORK/Localizable.xcstrings"
if [ -f "$CATALOG" ]; then
  cp "$CATALOG" "$TMP_CATALOG"
else
  cat > "$TMP_CATALOG" <<'JSON'
{
  "sourceLanguage" : "en",
  "strings" : {

  },
  "version" : "1.0"
}
JSON
fi

python3 "$WORK/localize.py" prune "$TMP_CATALOG" "$EXTRACT_KEYS"

echo "==> Syncing $CATALOG" >&2
SYNC_ARGS=()
while IFS= read -r stringsdata; do
  [ -n "$stringsdata" ] && SYNC_ARGS+=(--stringsdata "$stringsdata")
done < "$EXTRACT_LIST"
if [ "${#SYNC_ARGS[@]}" -eq 0 ]; then
  echo "error: no extracted stringsdata for $SOURCES" >&2
  exit 1
fi
if ! "$XCSTRINGSTOOL" sync "$TMP_CATALOG" "${SYNC_ARGS[@]}" >"$WORK/sync.log" 2>&1; then
  cat "$WORK/sync.log" >&2
  echo "error: xcstringstool sync failed" >&2
  exit 1
fi

LANGUAGE_LIST="$(IFS=,; echo "${LANGUAGES[*]}")"
python3 "$WORK/localize.py" finish "$MODE" "$TMP_CATALOG" "$CATALOG" "$LANGUAGE_LIST" "$BUNDLE"
