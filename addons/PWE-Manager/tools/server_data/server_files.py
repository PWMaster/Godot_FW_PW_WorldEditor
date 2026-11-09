#!/usr/bin/env python3
# Kopiert die Map-Dateien, die der Godot-Server je Server-Ordner braucht, aus den entpackten
# Server-Daten (FW_496 server-fw/gamed/config/<Ordner>/) nach Server/data/<Ordner>/ des Plugins:
#   map.bht       Kollision (Brushes, Server/brushes.gd; der Client baut daraus die Gebäude)
#   terrain.cfg   Raster des Terrains (Zeilen / Spalten der Teilkarten, Größe, Höhenbereich)
#   map/<n>.hmap  Höhen je Teilkarte (Server/heightmap.gd), nur die nRow * nCol, die terrain.cfg
#                 nennt (manche Ordner haben übrige Dateien)
# Aufruf: python3 server_files.py <config-Ordner> <Server/data> s9 s10 s11 s31
import os
import re
import shutil
import sys


def needed_hmaps(cfg_text):
    rows = int(re.search(r"nRow\s*=\s*(\d+)", cfg_text).group(1))
    cols = int(re.search(r"nCol\s*=\s*(\d+)", cfg_text).group(1))
    return ["%d.hmap" % (i + 1) for i in range(rows * cols)]


def copy_folder(src_root, dst_root, folder):
    src = os.path.join(src_root, folder)
    dst = os.path.join(dst_root, folder)
    if not os.path.isdir(src):
        print("%s: nicht gefunden" % src)
        return 0
    os.makedirs(os.path.join(dst, "map"), exist_ok=True)
    total = 0
    names = ["map.bht", "terrain.cfg"]
    cfg = os.path.join(src, "terrain.cfg")
    if os.path.exists(cfg):
        with open(cfg, encoding="latin-1") as f:
            names += ["map/" + h for h in needed_hmaps(f.read())]
    for name in names:
        s = os.path.join(src, name)
        if not os.path.exists(s):
            print("%s: %s fehlt" % (folder, name))
            continue
        shutil.copyfile(s, os.path.join(dst, name))
        total += os.path.getsize(s)
    print("%s: %s (%.1f MB)" % (folder, ", ".join(names), total / 1e6))
    return total


def main():
    if len(sys.argv) < 4:
        print(__doc__ or "python3 server_files.py <config-Ordner> <Server/data> <Ordner> ...")
        sys.exit(1)
    total = sum(copy_folder(sys.argv[1], sys.argv[2], f) for f in sys.argv[3:])
    print("zusammen %.1f MB" % (total / 1e6))


if __name__ == "__main__":
    main()
