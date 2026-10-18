#!/usr/bin/env python3
"""Checks that every `localized("…")` key in Sources has a Spanish translation with the same format
specifiers, and that the strings files have no unused entries. Run from the repository root."""

import json
import pathlib
import re
import subprocess
import sys

RESOURCES = pathlib.Path("Sources/TalktrailCore/Resources")
KEY = re.compile(r'localized\(\s*"((?:[^"\\]|\\.)*)"')
SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfeEgGcCsSp%])")
IDENTIFIER = re.compile(r"^[a-z]+(\.[a-z]+)+$")


def used_keys():
    keys = set()
    for path in pathlib.Path("Sources").rglob("*.swift"):
        for match in KEY.finditer(path.read_text()):
            keys.add(match.group(1).replace('\\"', '"').replace("\\\\", "\\"))
    return keys


def strings(language):
    path = RESOURCES / f"{language}.lproj/Localizable.strings"
    output = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)], check=True, capture_output=True)
    return json.loads(output.stdout)


def specifiers(text):
    return sorted(kind for kind in SPECIFIER.findall(text) if kind != "%")


keys = used_keys()
spanish = strings("es")
english = strings("en")
problems = []
problems += [f"es: missing translation for {key!r}" for key in sorted(keys - spanish.keys())]
problems += [f"es: unused entry {key!r}" for key in sorted(spanish.keys() - keys)]
problems += [f"en: unused entry {key!r}" for key in sorted(english.keys() - keys)]
problems += [f"en: missing text for {key!r}" for key in sorted(keys) if IDENTIFIER.match(key) and key not in english]
for key, value in spanish.items():
    source = english.get(key, key)
    if specifiers(value) != specifiers(source):
        problems.append(f"es: format specifiers of {key!r} do not match the English text")

for problem in problems:
    print(problem, file=sys.stderr)
print(f"{len(keys)} keys, {len(problems)} problems")
sys.exit(1 if problems else 0)
