"""Builds SuperOTP/Localizable.xcstrings from scripts/strings_zh.py and checks that every
localizable literal in the Swift sources has a translation."""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from strings_zh import EN_ONE, ZH  # noqa: E402

# Calls whose first string literal argument is a LocalizedStringKey / localized String.
CALLS = (
    r"Text|Button|Label|Toggle|Section|TextField|SecureField|Picker|Menu|LabeledContent|ProgressView|"
    r"ContentUnavailableView|SettingsLabel|String\(localized:|\.navigationTitle|\.alert|feature\([^,]+,|"
    r"title:|action:|return|\?|:"
)
LITERAL = r'"((?:[^"\\]|\\.|\\\((?:[^()]|\([^()]*\))*\))*)"'
INT_HINTS = ("count", "ungrouped", "writeCount", "added", "replaced", "skipped", "invalid", "skippedOtherTypes", "backupKeep")


def key_for(literal):
    def sub(match):
        expr = match.group(1)
        return "%lld" if any(h in expr for h in INT_HINTS) else "%@"
    return re.sub(r"\\\(((?:[^()]|\([^()]*\))*)\)", sub, literal).replace("\\n", "\n")


def used_keys():
    keys = {}
    for path in glob.glob(os.path.join(ROOT, "SuperOTP", "**", "*.swift"), recursive=True):
        src = open(path, encoding="utf-8").read()
        for match in re.finditer(r"(?:" + CALLS + r")\s*\(?\s*" + LITERAL, src):
            literal = match.group(1)
            before = src[max(0, match.start() - 20):match.start()]
            if "verbatim" in src[match.start():match.end()] or "systemImage" in before:
                continue
            keys.setdefault(key_for(literal), os.path.relpath(path, ROOT))
    return keys


def looks_like_ui_text(key):
    """Drops SF Symbol names, identifiers, Info.plist keys and fragments the regex cut short."""
    if "\n" in key and not key.endswith("%@") or "\\(" in key or "(" in key and "%" not in key and " " not in key:
        return False
    if key.startswith("CFBundle") or key in {"SuperOTP", "SuperOTP/1.0", "User-Agent", "其他", "Backups"}:
        return False
    if re.fullmatch(r"[a-z0-9.\-%@lld:]+", key) or re.fullmatch(r"[A-Z]{3,5}", key):
        return False
    if re.fullmatch(r"[a-z][A-Za-z0-9]*", key):
        return False
    if re.fullmatch(r"[#%@lld ·]+", key) or key.startswith(("Keychain:", "OSStatus")):
        return False
    return re.search(r"[A-Za-z]{2}", key) is not None


def main():
    strings = {}
    for key in sorted(ZH, key=str.lower):
        entry = {"localizations": {"zh-Hans": {"stringUnit": {"state": "translated", "value": ZH[key]}}}}
        if key in EN_ONE:
            entry["localizations"]["en"] = {
                "variations": {
                    "plural": {
                        "one": {"stringUnit": {"state": "translated", "value": EN_ONE[key]}},
                        "other": {"stringUnit": {"state": "translated", "value": key}},
                    }
                }
            }
        strings[key] = entry
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    with open(os.path.join(ROOT, "SuperOTP", "Localizable.xcstrings"), "w", encoding="utf-8") as out:
        json.dump(catalog, out, ensure_ascii=False, indent=2, sort_keys=False)
        out.write("\n")
    missing = {k: v for k, v in used_keys().items() if k not in ZH and looks_like_ui_text(k)}
    for key, path in sorted(missing.items()):
        print(f"MISSING: {key!r}  ({path})")
    print(f"{len(strings)} keys written, {len(missing)} candidates without translation")


if __name__ == "__main__":
    main()
