#!/usr/bin/env python3
"""Work out which extra include directories this trimmed kernel tree needs.

The vendor tree is built with an internal build system that supplies include
paths the upstream-style Makefiles here do not carry. Two distinct cases come
up, and they must be handled differently:

  * A header included with angle brackets that sits next to the including file.
    The compiler never searches the source directory for <> includes, so that
    directory has to be on the path.

  * A header referenced from a different directory. Only safe to satisfy when
    the name is unique in the tree; otherwise the choice is ambiguous.

The second case is what makes a single global path list unusable: Mali ships
nine copies of mali_kbase_defs.h (eight Bifrost revisions plus Valhall), and a
global -idirafter list puts them all on one search path in alphabetical order,
so a Bifrost build silently picks up another revision's struct layout. The same
applies to the two audio_ipi_dma.h variants and the per-SoC ppm/swpm headers.

So directories whose header name is ambiguous are written to the "local" list
and injected into their own Makefile instead, where they only affect that
subtree. Unambiguous ones go to the "global" list.

Usage: scan_includes.py <kernel-root> <glob-out> <local-out>
"""
import os
import re
import sys

# Only the trees the vendor trimmed need help. fs/, net/ and security/ are
# intact upstream subsystems whose Makefiles already resolve their own headers;
# adding them here would put e.g. fs/ocfs2/file.h on the search path and hijack
# legitimate <file.h> references.
TOPS = ["arch/arm64", "drivers", "sound"]

ANGLE = re.compile(r'^\s*#\s*include\s*<([^>\n]+\.h)>', re.M)
QUOTE = re.compile(r'^\s*#\s*include\s*"([^"\n]+\.h)"', re.M)


def main():
    root, glob_out, local_out = sys.argv[1:4]

    angles, quotes = {}, {}
    for top in TOPS:
        base = os.path.join(root, top)
        if not os.path.isdir(base):
            continue
        for d, _, files in os.walk(base):
            if "/.git" in d:
                continue
            for f in files:
                if not f.endswith((".c", ".h")):
                    continue
                try:
                    text = open(os.path.join(d, f), errors="ignore").read()
                except OSError:
                    continue
                for m in ANGLE.finditer(text):
                    angles.setdefault(m.group(1), set()).add(d)
                for m in QUOTE.finditer(text):
                    quotes.setdefault(m.group(1), set()).add(d)

    index = {}
    for top in TOPS:
        base = os.path.join(root, top)
        if not os.path.isdir(base):
            continue
        for d, _, files in os.walk(base):
            if "/.git" in d:
                continue
            for f in files:
                if f.endswith(".h"):
                    index.setdefault(f, set()).add(d)

    def homes(name):
        # A path-qualified include (<mach/foo.h>) is resolved by the driver's
        # own -I; only bare names can be indexed by filename.
        return set() if "/" in name else index.get(name, set())

    glob_dirs, local_dirs = set(), set()

    for name, srcs in angles.items():
        where = homes(name)
        if not where:
            continue
        same = srcs & where
        if same:
            if len(where) > 1:
                local_dirs |= same       # ambiguous: scope to this subtree
            else:
                glob_dirs |= same
        elif len(where) == 1:
            glob_dirs |= where           # cross-dir but unambiguous

    for name, srcs in quotes.items():
        where = homes(name)
        if not where:
            continue
        # A quoted include already searches the includer's own directory, so
        # only an includer living elsewhere matters, and only when unique.
        if (srcs - where) and len(where) == 1:
            glob_dirs |= where

    with open(glob_out, "w") as fh:
        fh.write("\n".join(sorted(glob_dirs)))
    with open(local_out, "w") as fh:
        fh.write("\n".join(sorted(local_dirs)))

    print("include scan: %d global dirs, %d subtree-scoped dirs"
          % (len(glob_dirs), len(local_dirs)))


if __name__ == "__main__":
    main()
