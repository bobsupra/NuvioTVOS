#!/usr/bin/env python3
"""
sync_android_translations.py

Synchronizes translations from Android TV (NuvioTVandroid/app/src/main/res)
into the tvOS catalog (tvosApp/NuvioTV/Resources/AppLanguageCatalog.json).

1. Extracts any newly added L10n.string / L10n.format keys and inline fallbacks from Swift source files.
2. Merges missing source keys into English.
3. Imports translations from matching Android TV string resources across all 38 supported languages.
4. Validates placeholder counts (%1$s, %d, etc.) for safety.
5. Safely falls back to English for any keys not yet translated.
6. Formats and alphabetically sorts AppLanguageCatalog.json.
"""

import argparse
import collections
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ANDROID_LANGUAGE_MAP = {
    "values": "en",
    "values-ar": "ar",
    "values-bg": "bg",
    "values-bn": "bn",
    "values-bs": "bs",
    "values-cs": "cs",
    "values-da": "da",
    "values-de": "de",
    "values-el": "el",
    "values-es": "es",
    "values-b+es+419": "es-419",
    "values-fr": "fr",
    "values-iw": "he",
    "values-hi": "hi",
    "values-hr": "hr",
    "values-hu": "hu",
    "values-in": "in",
    "values-it": "it",
    "values-ja": "ja",
    "values-lt": "lt",
    "values-nl": "nl",
    "values-no": "no",
    "values-pl": "pl",
    "values-pt-rBR": "pt-BR",
    "values-pt-rPT": "pt-PT",
    "values-ro": "ro",
    "values-ru": "ru",
    "values-sk": "sk",
    "values-sl": "sl",
    "values-sq": "sq",
    "values-b+sr+Latn": "sr-Latn",
    "values-sv": "sv",
    "values-ta": "ta",
    "values-tr": "tr",
    "values-uk": "uk",
    "values-vi": "vi",
    "values-zh-rCN": "zh-CN",
    "values-zh-rTW": "zh-TW",
}

PLACEHOLDER_PATTERN = re.compile(r"%(?:\d+\$)?[0-9.]*[@a-zA-Z]")
KEY_PATTERN = re.compile(r'(?:L10n\.)?(?:string|format)\(\s*"([^"]+)"')
FALLBACK_PATTERN = re.compile(r'(?:L10n\.)?(?:string|format)\(\s*"([^"]+)"\s*,\s*(?:fallback:\s*)?"([^"]*)"')


def placeholder_counts(value: str) -> collections.Counter:
    return collections.Counter(PLACEHOLDER_PATTERN.findall(value))


def extract_source_keys(sources_dir: Path) -> tuple[set[str], dict[str, str]]:
    source_keys = set()
    source_fallbacks = {}
    for p in sources_dir.rglob("*.swift"):
        content = p.read_text(encoding="utf-8", errors="replace")
        for k in KEY_PATTERN.findall(content):
            source_keys.add(k)
        for k, fb in FALLBACK_PATTERN.findall(content):
            if k not in source_fallbacks:
                source_fallbacks[k] = fb
    return source_keys, source_fallbacks


def load_android_strings(res_dir: Path) -> dict[str, dict[str, str]]:
    android_strings = {}
    for folder, lang in ANDROID_LANGUAGE_MAP.items():
        xml_file = res_dir / folder / "strings.xml"
        strings = {}
        if xml_file.exists():
            try:
                tree = ET.parse(xml_file)
                for s in tree.getroot().findall("string"):
                    name = s.get("name")
                    text = s.text
                    if name and text:
                        clean_text = text.replace(r"\'", "'").replace(r'\"', '"')
                        strings[name] = clean_text
            except Exception as e:
                print(f"Warning: Failed to parse {xml_file}: {e}", file=sys.stderr)
        android_strings[lang] = strings
    return android_strings


def sync_catalog(catalog_path: Path, sources_dir: Path, res_dir: Path) -> bool:
    print(f"Loading catalog: {catalog_path}")
    with open(catalog_path, "r", encoding="utf-8") as f:
        catalog = json.load(f)

    if "en" not in catalog:
        catalog["en"] = {}

    print(f"Scanning Swift source files: {sources_dir}")
    source_keys, source_fallbacks = extract_source_keys(sources_dir)
    print(f"  Found {len(source_keys)} source keys in Swift code.")

    # 1. Merge missing source keys into English
    new_en_keys = 0
    for k in sorted(source_keys):
        if k not in catalog["en"] or not catalog["en"][k]:
            catalog["en"][k] = source_fallbacks.get(k, k)
            new_en_keys += 1
    if new_en_keys:
        print(f"  Added {new_en_keys} new keys to 'en' catalog from Swift fallbacks.")

    total_en_keys = len(catalog["en"])
    print(f"  Total English keys: {total_en_keys}")

    print(f"Loading Android TV string resources: {res_dir}")
    android_strings = load_android_strings(res_dir)
    android_en = android_strings.get("en", {})
    print(f"  Loaded Android TV strings across {len(android_strings)} languages.")

    # Build Android text -> key mapping for normalized matching
    android_text_map = {}
    for a_key, a_val in android_en.items():
        norm = a_val.strip().replace(r"\'", "'").replace(r"\n", " ").lower()
        android_text_map.setdefault(norm, []).append(a_key)

    # Match tvOS keys to Android TV keys
    matched_keys = {}
    for tvos_key, tvos_text in catalog["en"].items():
        norm = tvos_text.strip().replace("\n", " ").lower()
        if tvos_key in android_en:
            matched_keys[tvos_key] = tvos_key
        elif norm in android_text_map:
            matched_keys[tvos_key] = android_text_map[norm][0]

    print(f"  Matched {len(matched_keys)} tvOS keys to Android TV strings.")

    # 2. Populate non-English languages
    imported_count = collections.defaultdict(int)
    fallback_count = collections.defaultdict(int)

    for lang in sorted(catalog.keys()):
        if lang == "en":
            continue
        table = catalog[lang]
        # Remove any keys not in English
        extra_keys = set(table) - set(catalog["en"])
        for ek in extra_keys:
            del table[ek]

        for key, en_text in catalog["en"].items():
            current_val = table.get(key)
            # If missing or identical to English fallback, try to import from Android TV
            if not current_val or not current_val.strip() or current_val == en_text:
                a_key = matched_keys.get(key)
                a_trans = android_strings.get(lang, {}).get(a_key) if a_key else None
                if a_trans and a_trans.strip() and placeholder_counts(en_text) == placeholder_counts(a_trans):
                    table[key] = a_trans
                    imported_count[lang] += 1
                elif not current_val or not current_val.strip():
                    table[key] = en_text
                    fallback_count[lang] += 1

    # 3. Sort and write catalog
    sorted_catalog = {
        lang: {k: catalog[lang][k] for k in sorted(catalog[lang].keys())}
        for lang in sorted(catalog.keys())
    }

    with open(catalog_path, "w", encoding="utf-8") as f:
        json.dump(sorted_catalog, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"\nCatalog update successful!")
    print(f"  Total translations imported from Android TV: {sum(imported_count.values())}")
    print(f"  Total English keys: {total_en_keys}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--catalog",
        default="tvosApp/NuvioTV/Resources/AppLanguageCatalog.json",
        help="Path to AppLanguageCatalog.json",
    )
    parser.add_argument(
        "--sources",
        default="tvosApp/NuvioTV/Sources",
        help="Path to Swift sources directory",
    )
    parser.add_argument(
        "--res",
        default="NuvioTVandroid/app/src/main/res",
        help="Path to Android TV res directory",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    catalog_path = Path(args.catalog)
    sources_dir = Path(args.sources)
    res_dir = Path(args.res)

    if not catalog_path.is_absolute():
        catalog_path = repo_root / catalog_path
    if not sources_dir.is_absolute():
        sources_dir = repo_root / sources_dir
    if not res_dir.is_absolute():
        res_dir = repo_root / res_dir

    success = sync_catalog(catalog_path, sources_dir, res_dir)
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
