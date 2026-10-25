#!/usr/bin/env python3
"""Build the tar.gz fixtures of tests/t_backup.sh. Run once, by hand; the tests only read the archives, they never run Python.

    python3 -I make_archives.py        # (re)writes the archives beside this file

tarfile writes link and device members as plain headers, so nothing here needs privilege or a filesystem that supports
them. The output is reproducible: mtime 0, owner mc:mc (1000:1000), GNU format, no name or time in the gzip header.
"""
import gzip
import io
import os
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))


def m(name, kind=tarfile.REGTYPE, data=b"", link="", **extra):
    ti = tarfile.TarInfo(name)
    ti.type, ti.linkname, ti.mtime = kind, link, 0
    ti.uid = ti.gid = 1000
    ti.uname = ti.gname = "mc"
    ti.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
    ti.size = len(data) if kind == tarfile.REGTYPE else 0
    for k, v in extra.items():
        setattr(ti, k, v)
    return ti, (io.BytesIO(data) if kind == tarfile.REGTYPE else None)


D = tarfile.DIRTYPE
LEVEL = b"level\n"
ARCHIVES = {
    # the two accepted layouts: members as they are in data/, or all under one top-level data/
    "clean.tar.gz": [m("world", D), m("world/level.dat", data=LEVEL)],
    "clean-wrapped.tar.gz": [m("data", D), m("data/world", D), m("data/world/level.dat", data=LEVEL)],
    # names with dots that are not a .. component, and a space
    "names.tar.gz": [m("world", D), m("world/a..b", data=b"x\n"), m("world/..c", data=b"x\n"),
                     m("world/c..", data=b"x\n"), m("world/my file.dat", data=b"x\n")],
    # hostile: links, an absolute path, .. components, a device, a newline in a name
    "symlink.tar.gz": [m("world", D), m("world/level.dat", data=LEVEL), m("world/escape", tarfile.SYMTYPE, link="/etc")],
    "symlink-rel.tar.gz": [m("world", D), m("world/level.dat", data=LEVEL), m("world/escape", tarfile.SYMTYPE, link="../..")],
    "hardlink.tar.gz": [m("world", D), m("world/level.dat", data=LEVEL),
                        m("world/copy", tarfile.LNKTYPE, link="world/level.dat")],
    "abs-path.tar.gz": [m("world/level.dat", data=LEVEL), m("/tmp/mcctl-abs-escape", data=b"x\n")],
    "dotdot.tar.gz": [m("world/level.dat", data=LEVEL), m("../escape", data=b"x\n"),
                      m("world/../../escape2", data=b"x\n"), m("world/..", D)],
    "device.tar.gz": [m("world/level.dat", data=LEVEL), m("world/null", tarfile.CHRTYPE, devmajor=1, devminor=3)],
    "newline.tar.gz": [m("world/level.dat", data=LEVEL), m("world/a\nb", data=b"x\n")],
    # tar does not escape owner names: a newline in one adds a line to `tar -tv` only
    "owner-newline.tar.gz": [m("world/level.dat", data=LEVEL, uname="mc\n-rw-r--r--")],
    # layout: data/ next to another top-level name is neither layout
    "mixed.tar.gz": [m("data", D), m("data/world/level.dat", data=LEVEL), m("plugins", D), m("plugins/x.jar", data=b"x\n")],
    # no members at all
    "empty.tar.gz": [],
}

for fname, members in ARCHIVES.items():
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for ti, f in members:
            tf.addfile(ti, f)
    with open(os.path.join(HERE, fname), "wb") as out:
        with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=0) as gz:
            gz.write(raw.getvalue())
    print(fname)
