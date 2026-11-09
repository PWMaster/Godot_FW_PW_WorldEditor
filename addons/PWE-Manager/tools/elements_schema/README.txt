Erzeugt angelica_elements_schema.json (Beschreibung für angelica_elements.gd).
Nur nötig, wenn eine elements.data einer anderen Version gelesen werden soll.

Eingaben (in diesen Ordner, UTF-8):
  iconv -f GBK -t UTF-8 <v260_server>/wgame_20131107/gs/template/exptypes.h      > exptypes.h
  iconv -f GBK -t UTF-8 <v260_server>/wgame_20131107/gs/template/elementdataman.cpp > edm.cpp
  iconv -f GBK -t UTF-8 <v260_server>/wgame_20131107/gs/template/elementdataman.h   > edm.h
Dateien über Umgebungsvariablen:
  CLIENT_ELEMENTS = neue elements.data (z.B. Client v297)
  SERVER_ELEMENTS = ältere elements.data mit v260-Satzgrößen (z.B. FW_496 Server, v253)
  ELEMENTS_DB     = ElementsV1.db (Ausrüstung mit Werten der neuen Version)

Ablauf:
  python3 gen_schema.py exptypes.h schema.json      Strukturen, Offsets (pack 4)
  python3 align.py                                 Einfügestellen je gewachsenem Typ (Vergleich gleicher IDs)
  python3 align_db.py                              Einfügestellen der Ausrüstung (Vergleich mit der DB)
  python3 bundle.py ../../Data/angelica_elements_schema.json
bundle.py trägt die Einfügestellen unter der Version der CLIENT_ELEMENTS-Datei ein
(derzeit fest 0x10000297 / 0x10000253 in bundle.py, bei neuer Version dort anpassen).
