#!/usr/bin/env python3
"""Offline config lint for Wintility.

Mirrors the rules in core/Config.ps1 so the JSON can be checked without Windows.
Run from the repo root:  python3 tests/validate_config.py
Exit code 0 = pass, 1 = fail.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "config"

ID_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]{2,63}$")
REG_PATH_RE = re.compile(r"^(HKCU|HKLM):\\")
RISKS = {"Low", "Medium", "High"}
TABS = ["Personalization", "Performance", "Ads", "Privacy", "Internet", "Storage", "Debloat"]
TWEAK_FILES = ["personalization", "performance", "privacy", "ads", "internet", "storage", "debloat"]
ACTIONS = {"registry"}
REG_TYPES = {"DWord", "QWord", "String"}
FLAGS = ["requiresAdmin", "requiresRestart", "requiresLogoff", "reversible", "enabledByDefault"]


def load(name, problems):
    path = CONFIG / f"{name}.json"
    if not path.exists():
        problems.append(f"{name}.json: file missing")
        return None
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as exc:
        problems.append(f"{name}.json: invalid JSON ({exc})")
        return None


def matches_type(value, typ):
    if typ == "String":
        return isinstance(value, str)
    if typ in ("DWord", "QWord"):
        return isinstance(value, int) and not isinstance(value, bool)
    return False


def check_registry(label, item, problems):
    reg = item.get("registry")
    entries = reg if isinstance(reg, list) else ([reg] if reg else [])
    if not entries:
        problems.append(f"{label}: has no registry values")
    touches_machine = False
    for number, entry in enumerate(entries, 1):
        where = f"{label} (value {number})"
        path = str(entry.get("path") or "")
        if not REG_PATH_RE.match(path):
            problems.append(f"{where}: registry path must start with HKCU:\\ or HKLM:\\")
        elif path.upper().startswith("HKLM:"):
            touches_machine = True
        if not str(entry.get("name") or "").strip():
            problems.append(f"{where}: registry value name missing")
        typ = entry.get("type")
        if typ not in REG_TYPES:
            problems.append(f"{where}: registry type must be DWord, QWord or String")
        if "appliedValue" not in entry:
            problems.append(f"{where}: appliedValue missing")
        elif not matches_type(entry["appliedValue"], typ):
            problems.append(f"{where}: appliedValue does not match type {typ}")
        has_default = "defaultValue" in entry
        removes = entry.get("removeOnRevert") is True
        if has_default and removes:
            problems.append(f"{where}: cannot have both defaultValue and removeOnRevert")
        if has_default and not matches_type(entry["defaultValue"], typ):
            problems.append(f"{where}: defaultValue does not match type {typ}")
    if touches_machine and item.get("requiresAdmin") is not True:
        problems.append(f"{label}: changes HKLM, so requiresAdmin must be true")


def check_settings(name, data, problems):
    ids = set()
    if data.get("schemaVersion") != 1:
        problems.append(f"{name}.json: schemaVersion must be 1")
    items = data.get("settings")
    if not isinstance(items, list) or not items:
        problems.append(f"{name}.json: 'settings' must be a non-empty list")
        return ids, []
    for item in items:
        sid = str(item.get("id") or "")
        label = f"{name}.json / {sid or '(no id)'}"
        if not ID_RE.match(sid):
            problems.append(f"{label}: invalid id")
            continue
        if sid in ids:
            problems.append(f"{label}: defined more than once")
        ids.add(sid)
        for field in ("name", "description", "category"):
            if not str(item.get(field) or "").strip():
                problems.append(f"{label}: no {field}")
        if item.get("tab") not in TABS:
            problems.append(f"{label}: unknown tab")
        if item.get("risk") not in RISKS:
            problems.append(f"{label}: unknown risk level")
        action = item.get("action")
        if action not in ACTIONS:
            problems.append(f"{label}: unknown action")
            continue
        for flag in FLAGS:
            if not isinstance(item.get(flag), bool):
                problems.append(f"{label}: '{flag}' must be true or false")
        if "requiresExplorerRestart" in item and not isinstance(item["requiresExplorerRestart"], bool):
            problems.append(f"{label}: 'requiresExplorerRestart' must be true or false")
        if item.get("reversible") is not True:
            problems.append(f"{label}: must be reversible")
        check_registry(label, item, problems)
    return ids, items


def check_presets(data, known_ids, problems):
    presets = data.get("presets")
    if not isinstance(presets, list) or not presets:
        problems.append("presets.json: no presets defined")
        return
    seen = set()
    for preset in presets:
        pname = str(preset.get("name") or "")
        if not pname:
            problems.append("presets.json: a preset has no name")
            continue
        if pname in seen:
            problems.append(f"presets.json: preset '{pname}' defined twice")
        seen.add(pname)
        refs = preset.get("settings") or []
        if not refs:
            problems.append(f"presets.json: preset '{pname}' has no settings")
        for ref in refs:
            if ref not in known_ids:
                problems.append(f"presets.json: preset '{pname}' references unknown setting '{ref}'")


def main():
    problems = []
    known = set()
    visible = {tab: 0 for tab in TABS}
    hidden_for_standard = 0
    total = 0
    for name in TWEAK_FILES:
        data = load(name, problems)
        if data is None:
            continue
        ids, items = check_settings(name, data, problems)
        for dup in sorted(known & ids):
            problems.append(f"setting '{dup}' is defined in more than one file")
        known |= ids
        for item in items:
            total += 1
            if item.get("requiresAdmin") is True:
                hidden_for_standard += 1
            elif item.get("tab") in visible:
                visible[item["tab"]] += 1
    # A tab other than Personalization must still have something for a standard user to see.
    for tab, count in visible.items():
        if tab != "Personalization" and count == 0:
            problems.append(f"tab {tab} has no tweaks that work without administrator access")
    presets = load("presets", problems)
    if presets is not None:
        check_presets(presets, known, problems)

    if problems:
        print("CONFIG LINT: FAIL")
        for p in problems:
            print(f"  - {p}")
        return 1
    shown = ", ".join(f"{tab} {count}" for tab, count in visible.items())
    print(f"CONFIG LINT: PASS ({total} tweaks; {hidden_for_standard} need admin and are hidden in a standard session)")
    print(f"  visible without admin: {shown}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
