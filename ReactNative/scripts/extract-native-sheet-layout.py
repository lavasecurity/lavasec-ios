#!/usr/bin/env python3
"""Compile the real component declarations, without importing the full app.

The emitted manifest identifies every exact source range and whole-file input.
No production layout expression is rewritten unless an explicit negative-control
mutation is requested; those mutated copies never replace repository source.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAFFOLD = "LavaSecApp/LavaDesignSystem/LavaScaffold.swift"
DECLARATIONS = [
    (SCAFFOLD, "struct LavaFullSheetHeader<"),
    (SCAFFOLD, "struct LavaToolbarIconButton:"),
    (SCAFFOLD, "struct NativeToolbarIconButton:"),
    (SCAFFOLD, "enum LavaActionRole:"),
    (SCAFFOLD, "private struct LavaCircularIconLabel:"),
    (SCAFFOLD, "private struct LavaToolbarIconSymbol:"),
    (SCAFFOLD, "struct LavaSetupPermissionIllustration:"),
    ("LavaSecApp/LavaDesignSystem/LavaComponents.swift", "struct LavaPlainCard<"),
    ("Shared/SoftShieldGuardian.swift", "struct LavaGuardianShieldShape:"),
    ("Shared/SoftShieldGuardian.swift", "private struct LavaGuardianPathMapper {"),
]
METHODS = ["    func lavaRowTitleText()", "    func lavaSupportingText()"]
WHOLE_FILES = [
    "LavaSecApp/LavaDesignSystem/LavaTokens.swift",
    "LavaSecApp/LavaStrings.swift",
    "Sources/LavaSecKit/LavaIconSize.swift",
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def declaration(source, marker):
    """A deliberately bounded lexer for these Swift declarations; fail closed."""
    matches = [i for i in range(len(source)) if source.startswith(marker, i)]
    if len(matches) != 1:
        raise ValueError(f"Expected one {marker!r}, found {len(matches)}")
    start = matches[0]
    begin = source.index("{", start)
    depth, i, state, block_depth = 0, begin, "code", 0
    while i < len(source):
        char, pair = source[i], source[i:i + 2]
        if state == "line":
            if char == "\n":
                state = "code"
        elif state == "block":
            if pair == "/*":
                block_depth += 1
                i += 1
            elif pair == "*/":
                block_depth -= 1
                i += 1
                if not block_depth:
                    state = "code"
        elif state == "string":
            if char == "\\":
                i += 1
            elif char == '"':
                state = "code"
        elif pair == "//":
            state = "line"
            i += 1
        elif pair == "/*":
            state, block_depth = "block", 1
            i += 1
        elif source[i:i + 3] == '"""' or pair == '#"':
            raise ValueError("Extend the extractor before adding raw/multiline strings")
        elif char == '"':
            state = "string"
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if not depth:
                return source[start:i + 1], source.count("\n", 0, start) + 1, source.count("\n", 0, i) + 1
        i += 1
    raise ValueError(f"Unclosed declaration {marker}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--mutation", choices=["none", "header-top", "independent-illustrations"], default="none")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = {"mutation": args.mutation, "declarations": [], "wholeFiles": []}
    sections = ["import SwiftUI\nimport UIKit\n"]

    def extract(path, marker):
        source = (ROOT / path).read_text()
        text, start, end = declaration(source, marker)
        manifest["declarations"].append({"path": path, "marker": marker, "startLine": start,
            "endLine": end, "sha256": digest(text.encode()), "sourceSHA256": digest(source.encode())})
        return text

    for path, marker in DECLARATIONS:
        sections.append(extract(path, marker))
    sections.append("extension View {\n" + "\n".join(extract(SCAFFOLD, method) for method in METHODS) + "\n}")
    source = "\n\n".join(sections) + "\n"
    mutations = {
        "header-top": (".padding(.top, LavaFullSheetMetrics.headerInset)", ".padding(.top, 8)"),
        "independent-illustrations": ("ForEach(Kind.allCases, id: \\.self)", "ForEach(Kind.allCases.filter { $0 == kind }, id: \\.self)"),
    }
    if args.mutation != "none":
        old, new = mutations[args.mutation]
        if source.count(old) != 1:
            raise ValueError("Negative control no longer matches exactly one production expression")
        source = source.replace(old, new)
        manifest["mutationReplacement"] = {"from": old, "to": new}
    (args.output / "ProductionSheetLayout.swift").write_text(source)
    manifest["generatedSHA256"] = digest(source.encode())
    for path in WHOLE_FILES:
        data = (ROOT / path).read_bytes()
        output = args.output / Path(path).name
        output.write_bytes(data)
        manifest["wholeFiles"].append({"path": path, "output": output.name, "sha256": digest(data)})
    (args.output / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
