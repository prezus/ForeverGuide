#!/usr/bin/env python3
"""
Decode and validate a ForeverGuide share (the text /fg share gives you), using only
Python 3's standard library: no ForeverGuide code, no packages.

    python3 decode_share.py share.txt       # a file holding the pasted part(s), in any order
    python3 decode_share.py < share.txt
    python3 decode_share.py --schema share-format.schema.json share.txt

Prints the decoded JSON. Exits with 1 and lists every problem when the text is not a
complete, intact share, or holds anything the published schema does not allow
(docs/share-format.schema.json, the format's allowlist). Other text around the parts,
such as your own notes, is ignored.

The format is described in docs/SHARE-FORMAT.md: "FG2:<part>/<parts>:<payload>", the
payloads joined in part order are base64 of zlib-compressed JSON ("FG2J": the JSON itself).
"""

import argparse
import base64
import binascii
import json
import os
import re
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SCHEMA = os.path.join(os.path.dirname(HERE), "docs", "share-format.schema.json")
HEADER = re.compile(r"\b(FG2J?):(\d+)/(\d+):")


class ShareError(Exception):
    pass


def join_parts(text):
    """The payload of every part, joined in part order."""
    heads = list(HEADER.finditer(text))
    if not heads:
        raise ShareError("no share found: a share starts with FG2:1/1: (or FG2J:1/1:)")
    tags = {m.group(1) for m in heads}
    totals = {int(m.group(3)) for m in heads}
    if len(tags) > 1 or len(totals) > 1:
        raise ShareError("the text holds parts of more than one share")
    tag, total = tags.pop(), totals.pop()
    parts = {}
    for m in heads:
        # base64 and compact JSON never hold a line break: a part runs to the end of its line
        payload = text[m.end():].split("\n", 1)[0].strip()
        n = int(m.group(2))
        if n in parts:
            raise ShareError("part %d is there twice" % n)
        parts[n] = payload
    missing = [n for n in range(1, total + 1) if n not in parts]
    if missing or len(parts) != total:
        raise ShareError("parts missing: %s of %d" % (", ".join(map(str, missing)) or "?", total))
    return tag, "".join(parts[n] for n in range(1, total + 1))


def no_duplicates(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise ShareError("key %r appears twice" % k)
        out[k] = v
    return out


def decode(text):
    tag, payload = join_parts(text)
    if tag == "FG2":
        try:
            raw = zlib.decompress(base64.b64decode(payload, validate=True))
        except (binascii.Error, ValueError) as e:
            raise ShareError("not valid base64 (was the copy cut short?): %s" % e)
        except zlib.error as e:
            raise ShareError("the compressed data is damaged or incomplete: %s" % e)
        try:
            payload = raw.decode("utf-8")
        except UnicodeDecodeError as e:
            raise ShareError("not UTF-8 text: %s" % e)
    try:
        return json.loads(payload, object_pairs_hook=no_duplicates)
    except json.JSONDecodeError as e:
        raise ShareError("not valid JSON: %s" % e)


def validate(value, schema, path="$"):
    """Problems with value under the JSON Schema subset the share schema uses."""
    errors = []
    if "const" in schema and value != schema["const"]:
        errors.append("%s: must be %r" % (path, schema["const"]))
    kind = schema.get("type")
    ok = {
        "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
        "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
        "string": lambda v: isinstance(v, str),
        "boolean": lambda v: isinstance(v, bool),
        "array": lambda v: isinstance(v, list),
        "object": lambda v: isinstance(v, dict),
    }
    if kind and not ok[kind](value):
        return errors + ["%s: must be %s" % (path, kind)]
    if kind == "string" and len(value) > schema.get("maxLength", len(value)):
        errors.append("%s: longer than %d characters" % (path, schema["maxLength"]))
    if kind == "array":
        if len(value) > schema.get("maxItems", len(value)):
            errors.append("%s: more than %d items" % (path, schema["maxItems"]))
        for i, item in enumerate(value):
            errors += validate(item, schema.get("items", {}), "%s[%d]" % (path, i))
    if kind == "object":
        if len(value) > schema.get("maxProperties", len(value)):
            errors.append("%s: more than %d entries" % (path, schema["maxProperties"]))
        for key in schema.get("required", []):
            if key not in value:
                errors.append("%s: %s is missing" % (path, key))
        pattern = schema.get("propertyNames", {}).get("pattern")
        props = schema.get("properties", {})
        extra = schema.get("additionalProperties", True)
        for key, item in value.items():
            if pattern and not re.search(pattern, key):
                errors.append("%s: %r is not an id" % (path, key))
            if key in props:
                errors += validate(item, props[key], "%s.%s" % (path, key))
            elif extra is False:
                errors.append("%s: %r is not allowed in a share" % (path, key))
            elif isinstance(extra, dict):
                errors += validate(item, extra, "%s.%s" % (path, key))
    return errors


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("file", nargs="?", help="text holding the share (default: standard input)")
    ap.add_argument("--schema", default=DEFAULT_SCHEMA, help="share-format.schema.json (default: %(default)s)")
    args = ap.parse_args(argv)
    if args.file:
        with open(args.file, encoding="utf-8") as fh:
            text = fh.read()
    else:
        text = sys.stdin.read()
    with open(args.schema, encoding="utf-8") as fh:
        schema = json.load(fh)
    try:
        doc = decode(text)
    except ShareError as e:
        print("not a valid share: %s" % e, file=sys.stderr)
        return 1
    problems = validate(doc, schema)
    print(json.dumps(doc, indent=2, ensure_ascii=False))
    if problems:
        print("\nthe share does not match the schema:", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        return 1
    print("\nvalid: a complete share, holding only what the schema allows", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
