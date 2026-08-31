#!/usr/bin/env python3
"""
translate_catalog.py

Extracts localized strings (L10n.string / L10n.format) from the Swift codebase,
merges new keys into English, and automatically translates missing strings
across all 34 supported languages in tvosApp/NuvioTV/Resources/AppLanguageCatalog.json.
"""

import argparse
import concurrent.futures
import json
import os
import random
import re
import sys
import time
import urllib.parse
import urllib.request

# Target languages mapping from catalog key to Google Translate API language code
LANGUAGE_MAP = {
    "ar": "ar",
    "bg": "bg",
    "bs": "bs",
    "cs": "cs",
    "da": "da",
    "de": "de",
    "el": "el",
    "en": "en",
    "es": "es",
    "es-419": "es",
    "fr": "fr",
    "he": "iw",
    "hi": "hi",
    "hu": "hu",
    "in": "id",
    "it": "it",
    "ja": "ja",
    "lt": "lt",
    "nl": "nl",
    "no": "no",
    "pl": "pl",
    "pt-BR": "pt",
    "pt-PT": "pt",
    "ro": "ro",
    "ru": "ru",
    "sk": "sk",
    "sl": "sl",
    "sv": "sv",
    "ta": "ta",
    "tr": "tr",
    "uk": "uk",
    "vi": "vi",
    "zh-CN": "zh-CN",
    "zh-TW": "zh-TW",
}

# Regex to match placeholders in formatted strings (%1$s, %2$d, %@, %d, %s, %f, %.1f, {0}, etc.)
PLACEHOLDER_REGEX = re.compile(
    r'(%[0-9]+\$[a-zA-Z]|%[@dsf]|%\.[0-9]+f|\{[0-9]+\}|%[a-zA-Z])'
)


def protect_placeholders(text: str):
    placeholders = []

    def repl(m):
        placeholders.append(m.group(0))
        return f"[[PH_{len(placeholders)-1}]]"

    protected = PLACEHOLDER_REGEX.sub(repl, text)
    return protected, placeholders


def restore_placeholders(text: str, placeholders: list) -> str:
    restored = text
    for i, ph in enumerate(placeholders):
        pattern = re.compile(r'\[\s*\[\s*PH_' + str(i) + r'\s*\]\s*\]', re.IGNORECASE)
        restored = pattern.sub(ph, restored)
    return restored


def translate_single(text: str, target_lang_code: str, source_lang: str = "en", max_retries: int = 4) -> str:
    if not text or not text.strip():
        return text

    protected, placeholders = protect_placeholders(text)
    encoded_query = urllib.parse.quote(protected)
    url = f"https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl={source_lang}&tl={target_lang_code}&q={encoded_query}"

    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }
    req = urllib.request.Request(url, headers=headers)

    for attempt in range(max_retries):
        try:
            with urllib.request.urlopen(req, timeout=12) as response:
                if response.status == 200:
                    raw_data = response.read().decode("utf-8")
                    data = json.loads(raw_data)
                    if isinstance(data, list) and len(data) > 0 and isinstance(data[0], str):
                        return restore_placeholders(data[0], placeholders)
                    elif isinstance(data, list) and len(data) > 0 and isinstance(data[0], list):
                        translated_segments = [part[0] for part in data[0] if part and part[0]]
                        translated_text = "".join(translated_segments)
                        return restore_placeholders(translated_text, placeholders)
        except Exception:
            sleep_time = (2 ** attempt) * 0.4 + random.uniform(0.1, 0.3)
            time.sleep(sleep_time)

    return text


def translate_batch(texts: list, target_lang_code: str, source_lang: str = "en") -> list:
    """Translates a batch of texts using numbered token delimiters with fallback to single translation."""
    if not texts:
        return []
    if len(texts) == 1:
        return [translate_single(texts[0], target_lang_code, source_lang)]

    all_protected = []
    all_placeholders = []
    for t in texts:
        p, phs = protect_placeholders(t)
        all_protected.append(p)
        all_placeholders.append(phs)

    delimiter_fmt = "\n\n[[_X_{:d}_X_]]\n\n"
    combined = ""
    for i, t in enumerate(all_protected):
        if i > 0:
            combined += delimiter_fmt.format(i)
        combined += t

    url = f"https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl={source_lang}&tl={target_lang_code}&q=" + urllib.parse.quote(combined)
    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }
    req = urllib.request.Request(url, headers=headers)

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if isinstance(data, list) and len(data) > 0 and isinstance(data[0], str):
                translated = data[0]
            elif isinstance(data, list) and len(data) > 0 and isinstance(data[0], list):
                translated = "".join([part[0] for part in data[0] if part and part[0]])
            else:
                translated = str(data)
            parts = re.split(r"\[\s*\[\s*_\s*X\s*_\s*\d+\s*_\s*X\s*_\s*\]\s*\]", translated)
            parts = [p.strip() for p in parts]
            if len(parts) == len(texts):
                return [restore_placeholders(parts[i], all_placeholders[i]) for i in range(len(texts))]
    except Exception:
        pass

    # Fallback to individual translations if batching failed or length mismatched
    return [translate_single(t, target_lang_code, source_lang) for t in texts]


def extract_l10n_from_sources(sources_dir: str) -> dict:
    """Scans Swift source files for L10n.string and L10n.format calls."""
    extracted = {}
    pattern = re.compile(
        r'L10n\.(?:string|format)\(\s*\"([^\"]+)\"\s*,\s*fallback:\s*\"([^\"]*)\"',
        re.DOTALL
    )

    for root, _, files in os.walk(sources_dir):
        for f in files:
            if f.endswith(".swift"):
                path = os.path.join(root, f)
                with open(path, "r", encoding="utf-8") as file:
                    content = file.read()
                    matches = pattern.findall(content)
                    for key, fallback in matches:
                        if key not in extracted:
                            extracted[key] = fallback

    return extracted


def main():
    parser = argparse.ArgumentParser(description="Translate AppLanguageCatalog.json")
    parser.add_argument(
        "--catalog",
        default="tvosApp/NuvioTV/Resources/AppLanguageCatalog.json",
        help="Path to AppLanguageCatalog.json"
    )
    parser.add_argument(
        "--sources",
        default="tvosApp/NuvioTV/Sources",
        help="Path to Swift sources directory"
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=6,
        help="Number of concurrent translation threads"
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=25,
        help="Number of strings per batch translation request"
    )
    parser.add_argument(
        "--target-langs",
        nargs="*",
        help="Specific language codes to translate (default: all)"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Only display missing keys without making translation requests"
    )
    args = parser.parse_args()

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    catalog_path = os.path.join(repo_root, args.catalog) if not os.path.isabs(args.catalog) else args.catalog
    sources_dir = os.path.join(repo_root, args.sources) if not os.path.isabs(args.sources) else args.sources

    if not os.path.exists(catalog_path):
        print(f"Error: Catalog not found at {catalog_path}", file=sys.stderr)
        sys.exit(1)

    with open(catalog_path, "r", encoding="utf-8") as f:
        catalog = json.load(f)

    if "en" not in catalog:
        catalog["en"] = {}

    print(f"🔍 Scanning Swift source files in {sources_dir}...")
    extracted_strings = extract_l10n_from_sources(sources_dir)
    print(f"   Found {len(extracted_strings)} localized strings in source code.")

    # Merge extracted strings into English
    new_en_count = 0
    for key, fallback in extracted_strings.items():
        if key not in catalog["en"] or not catalog["en"][key]:
            catalog["en"][key] = fallback
            new_en_count += 1

    if new_en_count > 0:
        print(f"   Added {new_en_count} new keys to 'en' dictionary.")

    total_en_keys = len(catalog["en"])
    print(f"   Total English keys: {total_en_keys}")

    # Determine languages to translate
    target_languages = args.target_langs if args.target_langs else [l for l in LANGUAGE_MAP.keys() if l != "en"]

    missing_by_lang = {}
    total_missing = 0
    for lang in target_languages:
        if lang not in catalog:
            catalog[lang] = {}
        target_table = catalog[lang]
        missing_keys = []
        for key, en_text in catalog["en"].items():
            if key not in target_table or not target_table[key] or target_table[key].strip() == "":
                missing_keys.append((key, en_text))
        if missing_keys:
            missing_by_lang[lang] = missing_keys
            total_missing += len(missing_keys)

    print(f"\n📊 Total missing translations to process: {total_missing}")
    for lang in sorted(missing_by_lang.keys()):
        print(f"   • {lang}: {len(missing_by_lang[lang])} missing keys")

    if args.dry_run:
        print("\n[Dry run] Skipping translation API requests.")
        return

    if not missing_by_lang:
        print("\n✅ All languages are 100% up to date!")
        return

    # Build batch tasks: list of (lang, [(key, en_text), ...])
    batch_tasks = []
    for lang, items in missing_by_lang.items():
        for i in range(0, len(items), args.batch_size):
            batch_tasks.append((lang, items[i:i + args.batch_size]))

    print(f"\n🌐 Translating in {len(batch_tasks)} batched requests ({args.concurrency} worker threads)...")
    completed_strings = 0
    start_time = time.time()

    def process_batch(task):
        lang, items = task
        lang_code = LANGUAGE_MAP.get(lang, lang)
        texts = [en_text for _, en_text in items]
        translated = translate_batch(texts, lang_code, source_lang="en")
        results = []
        for (k, _), trans in zip(items, translated):
            results.append((lang, k, trans))
        return results

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = [executor.submit(process_batch, task) for task in batch_tasks]
        for future in concurrent.futures.as_completed(futures):
            try:
                results = future.result()
                for lang, key, trans in results:
                    catalog[lang][key] = trans
                    completed_strings += 1

                percent = (completed_strings / total_missing) * 100
                elapsed = time.time() - start_time
                rate = completed_strings / elapsed if elapsed > 0 else 0
                print(f"   [{completed_strings}/{total_missing}] {percent:.1f}% translated ({rate:.1f} strings/sec)", end="\r", flush=True)
            except Exception as exc:
                print(f"\n   Worker error: {exc}", file=sys.stderr, flush=True)

    print(f"\n   Completed {completed_strings}/{total_missing} translations in {time.time() - start_time:.1f}s.", flush=True)

    # Sort each language's dictionary by key and sort languages
    sorted_catalog = {}
    for lang in sorted(catalog.keys()):
        sorted_catalog[lang] = {k: catalog[lang][k] for k in sorted(catalog[lang].keys())}

    print(f"\n💾 Saving updated catalog to {catalog_path}...", flush=True)
    with open(catalog_path, "w", encoding="utf-8") as f:
        json.dump(sorted_catalog, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"🎉 Successfully translated and updated all keys across {len(target_languages)} languages!", flush=True)


if __name__ == "__main__":
    main()
