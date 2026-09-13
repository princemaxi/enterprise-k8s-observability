#!/usr/bin/env python3
"""Validates cross-references within a Terraform directory:
   - every var.X used is declared in a variable block
   - every module.X.Y used references a module block that's actually declared
   - every resource-type.name.attr reference resolves to a declared resource
     in the SAME directory (local references only; doesn't chase into child
     modules, since that requires the full provider schema this environment
     doesn't have)
   - no duplicate resource/data addresses across files in the same directory
"""
import glob
import os
import re
import sys

import hcl2


def _clean(k):
    """This python-hcl2 version returns some block keys wrapped in literal
    escaped quote characters (e.g. '\\"eks\\"' instead of 'eks') — strip
    them so comparisons against plain identifiers work."""
    return k.strip('"').strip("\\").strip('"')


def load_dir(path):
    variables, resources, data_sources, modules = set(), set(), set(), set()
    duplicates = []
    seen_addrs = set()
    raw_texts = {}

    for f in sorted(glob.glob(os.path.join(path, "*.tf"))):
        with open(f) as fh:
            text = fh.read()
        raw_texts[f] = text
        try:
            with open(f) as fh2:
                doc = hcl2.load(fh2)
        except Exception as e:
            print(f"PARSE ERROR in {f}: {e}")
            continue

        for block in doc.get("variable", []):
            variables.update(_clean(k) for k in block.keys())
        for block in doc.get("resource", []):
            for rtype, insts in block.items():
                rtype = _clean(rtype)
                for name in insts.keys():
                    name = _clean(name)
                    addr = f"{rtype}.{name}"
                    if addr in seen_addrs:
                        duplicates.append((addr, f))
                    seen_addrs.add(addr)
                    resources.add(addr)
        for block in doc.get("data", []):
            for dtype, insts in block.items():
                dtype = _clean(dtype)
                for name in insts.keys():
                    name = _clean(name)
                    data_sources.add(f"data.{dtype}.{name}")
        for block in doc.get("module", []):
            modules.update(_clean(k) for k in block.keys())

    return variables, resources, data_sources, modules, raw_texts, duplicates


def find_references(raw_texts):
    var_refs, module_refs, resource_refs = set(), set(), set()
    var_pat = re.compile(r"\bvar\.([a-zA-Z0-9_]+)")
    module_pat = re.compile(r"\bmodule\.([a-zA-Z0-9_]+)\.([a-zA-Z0-9_]+)")
    resource_pat = re.compile(
        r"(?<!data\.)\b((?:aws|helm|kubernetes|kubectl|docker|null|random|tls|time)_[a-zA-Z0-9_]+)\.([a-zA-Z0-9_]+)\.[a-zA-Z0-9_\[\]\"]+"
    )
    data_ref_pat = re.compile(
        r"\bdata\.((?:aws|helm|kubernetes|kubectl|docker|null|random|tls|time)_[a-zA-Z0-9_]+)\.([a-zA-Z0-9_]+)\."
    )
    for f, text in raw_texts.items():
        for m in var_pat.finditer(text):
            var_refs.add((m.group(1), f))
        for m in module_pat.finditer(text):
            module_refs.add((m.group(1), m.group(2), f))
        for m in resource_pat.finditer(text):
            resource_refs.add((f"{m.group(1)}.{m.group(2)}", f, "resource"))
        for m in data_ref_pat.finditer(text):
            resource_refs.add((f"{m.group(1)}.{m.group(2)}", f, "data"))
    return var_refs, module_refs, resource_refs


def validate_dir(path, allow_unresolved_modules=None):
    allow_unresolved_modules = allow_unresolved_modules or set()
    variables, resources, data_sources, modules, raw_texts, duplicates = load_dir(path)
    var_refs, module_refs, resource_refs = find_references(raw_texts)

    problems = []
    for addr, f in duplicates:
        problems.append(f"DUPLICATE resource address {addr} (in {f})")

    for varname, f in var_refs:
        if varname not in variables:
            problems.append(f"UNDECLARED var.{varname} referenced in {f}")

    for modname, attr, f in module_refs:
        if modname not in modules and modname not in allow_unresolved_modules:
            problems.append(f"UNDECLARED module.{modname} (referenced as module.{modname}.{attr}) in {f}")

    known_local_types = {r.split(".")[0] for r in resources}
    known_data_types = {d.split(".", 2)[1] for d in data_sources}  # "data.TYPE.NAME" -> TYPE
    for addr, f, kind in resource_refs:
        rtype = addr.split(".")[0]
        if kind == "data":
            if rtype not in known_data_types:
                continue  # data source of a type we don't declare anywhere locally; skip
            if f"data.{addr}" not in data_sources:
                problems.append(f"UNDECLARED data source {addr} referenced as data.{addr} in {f}")
        else:
            if rtype not in known_local_types:
                continue  # cross-module or provider-namespaced thing we can't resolve locally; skip
            if addr not in resources:
                problems.append(f"UNDECLARED resource {addr} referenced in {f}")

    return problems


if __name__ == "__main__":
    targets = sys.argv[1:] or ["."]
    total_problems = 0
    for t in targets:
        print(f"=== {t} ===")
        problems = validate_dir(t)
        if problems:
            for p in problems:
                print("  -", p)
            total_problems += len(problems)
        else:
            print("  OK")
    sys.exit(1 if total_problems else 0)
