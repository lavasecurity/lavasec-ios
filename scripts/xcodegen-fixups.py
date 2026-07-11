#!/usr/bin/env python3
"""Post-generation fixups for LavaSec.xcodeproj/project.pbxproj.

Runs automatically as XcodeGen's `postGenCommand` (see project.yml), so plain
`xcodegen generate` always produces the final committed pbxproj. Each fixup covers a
project property XcodeGen 2.45.4 cannot express in the spec; drop the corresponding
block once a future XcodeGen release gains the capability. Phase C1 of lavasec-infra
plans/2026-07-07-ios-modularization-scaffolding-plan.md.

Fixups:
1. knownRegions — the app localizes via .xcstrings string catalogs (no .lproj variant
   groups), so XcodeGen emits only (Base, en); the spec has no knownRegions option.
   Restore the full region list Xcode shows in the project's Localizations panel.
   Derive it from Config/supported-locales.json, the same manifest consumed by the
   localization checks.
2. Icon Composer .icon bundles — XcodeGen's bundled XcodeProj predates Icon Composer
   and types them `wrapper.icon`; Xcode 26's actool needs `folder.iconcomposer.icon`
   to compile them into the asset catalog (alternate app icons included).
   pinned: LavaLiveActivitySourceTests.testLavaGuardLooksDeclareAlternateAppIcons

Idempotent: running against an already-fixed pbxproj is a no-op. Any other state
(pattern missing entirely — e.g. an XcodeGen upgrade changed its output) fails loudly
so drift surfaces here instead of in the pinned tests.
"""
import json
import os
import re
import sys
from pathlib import Path

IOS_ROOT = Path(os.environ.get("LAVASEC_IOS_ROOT", Path(__file__).resolve().parent.parent))
PBXPROJ = IOS_ROOT / "LavaSec.xcodeproj" / "project.pbxproj"
LOCALE_MANIFEST = IOS_ROOT / "Config" / "supported-locales.json"


def load_known_regions() -> list[str]:
    try:
        manifest = json.loads(LOCALE_MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        sys.exit(f"xcodegen-fixups: cannot read {LOCALE_MANIFEST}: {error}")

    locales = manifest.get("locales")
    if not isinstance(locales, list) or not locales or locales[0] != "en":
        sys.exit("xcodegen-fixups: supported-locales.json must list source locale en first")
    if any(not isinstance(locale, str) or not locale for locale in locales):
        sys.exit("xcodegen-fixups: supported-locales.json locales must be non-empty strings")
    if len(set(locales)) != len(locales) or "Base" in locales:
        sys.exit("xcodegen-fixups: supported-locales.json locales must be unique and exclude Base")

    # Base is an Xcode region rather than a shipped localization, so it stays out of the manifest.
    return [locales[0], "Base", *locales[1:]]


KNOWN_REGIONS = load_known_regions()


def fix_known_regions(text: str) -> str:
    region_block = "".join(f"\t\t\t\t{region},\n" for region in KNOWN_REGIONS)
    replacement = f"knownRegions = (\n{region_block}\t\t\t);"
    pattern = re.compile(r"knownRegions = \([^)]*\);")
    match = pattern.search(text)
    if match is None:
        sys.exit("xcodegen-fixups: no knownRegions block found — XcodeGen output changed shape?")
    if match.group(0) == replacement:
        return text
    return pattern.sub(replacement, text, count=1)


def fix_icon_composer_types(text: str) -> str:
    wrong = "lastKnownFileType = wrapper.icon;"
    right = "lastKnownFileType = folder.iconcomposer.icon;"
    if wrong not in text:
        if right not in text:
            sys.exit("xcodegen-fixups: no .icon file references found — expected 8 Icon Composer bundles.")
        return text
    return text.replace(wrong, right)


def main() -> None:
    text = PBXPROJ.read_text(encoding="utf-8")
    fixed = fix_icon_composer_types(fix_known_regions(text))
    if fixed != text:
        PBXPROJ.write_text(fixed, encoding="utf-8")
    print("xcodegen-fixups: pbxproj fixups applied")


if __name__ == "__main__":
    main()
