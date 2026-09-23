#!/usr/bin/env python3
"""Validate the tvOS localization catalog against the Swift source."""

import argparse
import collections
import json
import re
import sys
from pathlib import Path


SUPPORTED_LANGUAGES = {
    "ar", "bg", "bs", "cs", "da", "de", "el", "en", "es", "es-419",
    "fr", "he", "hi", "hu", "in", "it", "ja", "lt", "nl", "no", "pl",
    "pt-BR", "pt-PT", "ro", "ru", "sk", "sl", "sv", "ta", "tr", "uk",
    "vi", "zh-CN", "zh-TW",
}

KEY_PATTERN = re.compile(r'L10n\.(?:string|format)\(\s*"([^"]+)"')
PLACEHOLDER_PATTERN = re.compile(r'%(?:\d+\$)?[0-9.]*[@a-zA-Z]')


def source_keys(sources: Path) -> set[str]:
    keys: set[str] = set()
    for path in sources.rglob("*.swift"):
        keys.update(KEY_PATTERN.findall(path.read_text(encoding="utf-8", errors="replace")))
    return keys


def placeholder_counts(value: str) -> collections.Counter[str]:
    return collections.Counter(PLACEHOLDER_PATTERN.findall(value))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", default="tvosApp/NuvioTV/Resources/AppLanguageCatalog.json")
    parser.add_argument("--sources", default="tvosApp/NuvioTV/Sources")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    catalog_path = Path(args.catalog)
    sources_path = Path(args.sources)
    if not catalog_path.is_absolute():
        catalog_path = root / catalog_path
    if not sources_path.is_absolute():
        sources_path = root / sources_path

    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: cannot read catalog: {exc}", file=sys.stderr)
        return 1

    errors: list[str] = []
    languages = set(catalog)
    if languages != SUPPORTED_LANGUAGES:
        errors.append(
            "language set mismatch: "
            f"missing={sorted(SUPPORTED_LANGUAGES - languages)} "
            f"extra={sorted(languages - SUPPORTED_LANGUAGES)}"
        )

    english = catalog.get("en", {})
    if not isinstance(english, dict):
        errors.append("'en' must be an object")
        english = {}

    source_missing = sorted(source_keys(sources_path) - set(english))
    if source_missing:
        errors.append(f"{len(source_missing)} source keys missing from English: {', '.join(source_missing)}")

    for language, table in sorted(catalog.items()):
        if not isinstance(table, dict):
            errors.append(f"{language}: table must be an object")
            continue

        missing = sorted(set(english) - set(table))
        extra = sorted(set(table) - set(english))
        empty = sorted(key for key, value in table.items() if not isinstance(value, str) or not value.strip())
        if missing:
            errors.append(f"{language}: {len(missing)} missing keys")
        if extra:
            errors.append(f"{language}: {len(extra)} extra keys: {', '.join(extra)}")
        if empty:
            errors.append(f"{language}: {len(empty)} empty values: {', '.join(empty)}")

        for key in sorted(set(english) & set(table)):
            value = table[key]
            if not isinstance(value, str):
                continue
            if "PH_" in value or "[[_X_" in value:
                errors.append(f"{language}.{key}: leaked translation placeholder marker")
            if placeholder_counts(english[key]) != placeholder_counts(value):
                errors.append(
                    f"{language}.{key}: placeholder mismatch "
                    f"English={sorted(placeholder_counts(english[key]).elements())} "
                    f"translation={sorted(placeholder_counts(value).elements())}"
                )

    if errors:
        print("Translation validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1

    print(
        f"Translation validation passed: {len(catalog)} languages, "
        f"{len(english)} keys, {len(source_keys(sources_path))} source keys."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
