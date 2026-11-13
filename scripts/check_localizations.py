#!/usr/bin/env python3
"""Validate Xcode String Catalog keys, source translations and placeholders."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILE = ROOT / "TypeTypeTV" / "Localizable.xcstrings"
CATALOG = json.loads(FILE.read_text(encoding="utf-8"))
SOURCE = CATALOG.get("sourceLanguage")
STRINGS = CATALOG.get("strings", {})
if SOURCE != "de" or not STRINGS:
    sys.exit("Invalid catalog: German must be the source language")

PLACEHOLDERS = re.compile(r"(?<!%)%(?:[0-9]+\$)?(?:@|d|ld|lld|s|f|g)")
errors = []
languages = set()
for key, spec in STRINGS.items():
    if not re.fullmatch(r"[a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+", key):
        errors.append(f"{key}: semantic key required")
    localized = spec.get("localizations", {})
    source = localized.get(SOURCE, {}).get("stringUnit", {}).get("value")
    if not source:
        errors.append(f"{key}: missing German source text")
        continue
    expected = sorted(PLACEHOLDERS.findall(source))
    for lang, translation in localized.items():
        languages.add(lang)
        unit = translation.get("stringUnit", {})
        value = unit.get("value")
        if value is None:
            if "variations" not in translation:
                errors.append(f"{key}/{lang}: missing translation")
            continue
        if not value.strip():
            errors.append(f"{key}/{lang}: empty text")
        if sorted(PLACEHOLDERS.findall(value)) != expected:
            errors.append(f"{key}/{lang}: incompatible printf placeholders")

code = "\n".join(x.read_text(encoding="utf-8") for x in (ROOT / "TypeTypeTV").glob("*.swift"))
keys = re.findall(r'"((?:nav|home|search|library|setup|settings|language|certificate|error|player|video|common|login|server)\.[a-zA-Z0-9.]+)"', code)
for key in sorted(set(keys)):
    # SF Symbols such as "server.rack" are identifiers, not UI copy.
    if key in {"server.rack"}:
        continue
    if key not in STRINGS:
        errors.append(f"Missing catalog entry used by Swift: {key}")
print(f"Catalog: {len(STRINGS)} keys, {len(languages)} languages: {sorted(languages)}")
if errors:
    print("\n".join("ERROR: " + e for e in errors))
    sys.exit(1)
print("Translation resource validation passed.")
