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

Usage: scan_includes.py <kernel-root> <glob-out> <local-out> [platform]

Directories listed in $SOPP_SKIP (colon separated, relative to the kernel root)
are ignored entirely. They hold drivers the chosen config does not build, whose
headers must not be reachable: gud/ ships a second tee_client_api.h whose struct
definitions differ from MicroTrust's teei/ copy, and reaching it turns every
teei object into a redefinition error.
"""
import os
import re
import sys

# Only the trees the vendor trimmed need help. fs/, net/ and security/ are
# intact upstream subsystems whose Makefiles already resolve their own headers;
# adding them here would put e.g. fs/ocfs2/file.h on the search path and hijack
# legitimate <file.h> references.
TOPS = ["arch/arm64", "drivers", "sound"]

SKIP = [p for p in os.environ.get("SOPP_SKIP", "").split(":") if p]

ANGLE = re.compile(r'^\s*#\s*include\s*<([^>\n]+\.h)>', re.M)
QUOTE = re.compile(r'^\s*#\s*include\s*"([^"\n]+\.h)"', re.M)


def source_dirs(root, top):
    """Walk one top-level tree, pruning .git and the disabled subtree list."""
    base = os.path.join(root, top)
    if not os.path.isdir(base):
        return
    skipped = {os.path.normpath(os.path.join(root, s)) for s in SKIP}
    for d, dirs, files in os.walk(base):
        dirs[:] = [x for x in dirs
                   if os.path.normpath(os.path.join(d, x)) not in skipped]
        if "/.git" in d:
            continue
        yield d, files


def main():
    root, glob_out, local_out = sys.argv[1:4]
    platform = sys.argv[4] if len(sys.argv) > 4 else ""

    angles, quotes = {}, {}
    for top in TOPS:
        for d, files in source_dirs(root, top):
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
    # For a path-qualified include the directory to add is the one containing
    # that exact relative path, so index every path suffix up front instead of
    # walking the tree once per include.
    by_suffix = {}
    for top in TOPS:
        for d, files in source_dirs(root, top):
            for f in files:
                if not f.endswith(".h"):
                    continue
                index.setdefault(f, set()).add(d)
                rel = os.path.relpath(os.path.join(d, f), root).split(os.sep)
                for k in range(2, len(rel) + 1):
                    suf = "/".join(rel[-k:])
                    parent = os.sep.join(rel[:-k])
                    pri = os.path.join(root, parent) if parent else root
                    by_suffix.setdefault(suf, set()).add(pri)

    def homes(name):
        # A path-qualified include (<mach/foo.h>) is resolved by the driver's
        # own -I; only bare names can be indexed by filename.
        return set() if "/" in name else index.get(name, set())

    def qualified_roots(name):
        # For <inc/tcpci.h> the directory to put on the path is the one that
        # contains "inc/tcpci.h" itself, i.e. the parent of the qualifier.
        return by_suffix.get(name, set())

    def closest(srcs, where):
        """Pick the candidate sharing the longest path prefix with an includer.

        Several SoCs keep identically named headers (ppm/swpm/idle) and the
        tree is configured for exactly one of them; the includer sits inside
        that SoC's subtree, so the deepest shared prefix wins.
        """
        best, best_len = None, -1
        for cand in where:
            for s in srcs:
                n = 0
                a, b = s.split(os.sep), cand.split(os.sep)
                for x, y in zip(a, b):
                    if x != y:
                        break
                    n += 1
                if n > best_len:
                    best, best_len = cand, n
        return best

    glob_dirs, local_dirs = set(), set()

    for name, srcs in angles.items():
        if "/" in name:
            roots = qualified_roots(name)
            if len(roots) == 1:
                glob_dirs |= roots
            elif roots:
                pick = closest(srcs, roots)
                if pick:
                    # Several revisions carry the same qualified path (Mali's
                    # backend/ headers), so scope it to the subtree rather than
                    # racing them on one global list.
                    local_dirs.add(pick)
            continue
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
        elif where:
            # Per-SoC header picked by nobody in its own directory: prefer the
            # candidate under the configured platform, else the closest one.
            pref = {d for d in where if platform and platform in d}
            pick = None
            if len(pref) == 1:
                pick = pref.pop()
            elif not platform or not pref:
                pick = closest(srcs, where)
            if pick:
                glob_dirs.add(pick)

    for name, srcs in quotes.items():
        if "/" in name:
            roots = qualified_roots(name)
            if len(roots) == 1:
                glob_dirs |= roots
            elif roots:
                pick = closest(srcs, roots)
                if pick:
                    # Several revisions carry the same qualified path (Mali's
                    # backend/ headers), so scope it to the subtree rather than
                    # racing them on one global list.
                    local_dirs.add(pick)
            continue
        where = homes(name)
        if not where:
            continue
        # A quoted include already searches the includer's own directory, so
        # only an includer living elsewhere matters, and only when unique.
        if (srcs - where) and len(where) == 1:
            glob_dirs |= where
        elif (srcs - where) and len(where) > 1:
            pref = {d for d in where if platform and platform in d}
            pick = pref.pop() if len(pref) == 1 else closest(srcs, where)
            if pick:
                glob_dirs.add(pick)

    with open(glob_out, "w") as fh:
        fh.write("\n".join(sorted(glob_dirs)))
    with open(local_out, "w") as fh:
        fh.write("\n".join(sorted(local_dirs)))

    print("include scan: %d global dirs, %d subtree-scoped dirs"
          % (len(glob_dirs), len(local_dirs)))


if __name__ == "__main__":
    main()
