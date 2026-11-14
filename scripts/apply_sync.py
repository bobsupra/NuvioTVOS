#!/usr/bin/env python3
"""Synchronize AppLanguageCatalog.json with all missing keys and translations."""

import json
from pathlib import Path
from scripts.no_translations import NO_MAP
from scripts.fr_translations import FR_MAP

CATALOG_PATH = Path("tvosApp/NuvioTV/Resources/AppLanguageCatalog.json")

def main():
    with open(CATALOG_PATH, "r", encoding="utf-8") as f:
        catalog = json.load(f)

    en_keys = set(catalog["en"].keys())
    print(f"Total English keys: {len(en_keys)}")

    # Update Norwegian (no)
    no_table = catalog.setdefault("no", {})
    no_updated = 0
    for k, v in NO_MAP.items():
        if k in en_keys:
            no_table[k] = v
            no_updated += 1
    # Fallback any remaining
    for k in en_keys:
        if k not in no_table:
            no_table[k] = catalog["en"][k]
    print(f"Norwegian: updated/added {no_updated} translations, total keys: {len(no_table)}")

    # Update French (fr)
    fr_table = catalog.setdefault("fr", {})
    fr_updated = 0
    for k, v in FR_MAP.items():
        if k in en_keys:
            fr_table[k] = v
            fr_updated += 1
    # Fallback any remaining
    for k in en_keys:
        if k not in fr_table:
            fr_table[k] = catalog["en"][k]
    print(f"French: updated/added {fr_updated} translations, total keys: {len(fr_table)}")

    # Update all other languages
    for lang, table in catalog.items():
        if lang in ("en", "no", "fr"):
            continue
        missing_in_lang = en_keys - set(table.keys())
        for k in missing_in_lang:
            table[k] = catalog["en"][k]

    # Sort each language table alphabetically
    sorted_catalog = {}
    for lang in sorted(catalog.keys()):
        sorted_catalog[lang] = {k: catalog[lang][k] for k in sorted(catalog[lang].keys())}

    with open(CATALOG_PATH, "w", encoding="utf-8") as f:
        json.dump(sorted_catalog, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print("Successfully wrote updated catalog!")

if __name__ == "__main__":
    main()
