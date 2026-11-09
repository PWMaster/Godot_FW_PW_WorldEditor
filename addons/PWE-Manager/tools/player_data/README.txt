Erzeugt angelica_player_data.json (Aussehen der Spielfiguren für angelica_player.gd).

Eingaben (Client-Quellcode v260, nur als Nachschlagewerk; nach UTF-8 gewandelt):
  C=<27_2014_07_04_v260>/.../SMElement/SMElementClient
  iconv -f GBK -t UTF-8 -c $C/EC_PlayerUtil.cpp > EC_PlayerUtil.cpp
  iconv -f GBK -t UTF-8 -c $C/EC_Player.cpp > EC_Player.cpp
  iconv -f GBK -t UTF-8 -c $C/DlgCreateSelectStyle.cpp > DlgCreateSelectStyle.cpp

Ablauf:
  python3 extract.py EC_PlayerUtil.cpp EC_Player.cpp DlgCreateSelectStyle.cpp ../../ECM/angelica_player_data.json

Inhalt: Körper-.ecm je Rasse / Geschlecht, Muster für Kopf (Gesicht + 1, Maske) und Haare
(Frisur + 1), Standard-Mode (时装\默认), Standardkleidung je Rasse / Klasse / Geschlecht
(Oberteil, Hose, Schuhe, Handgelenk), Hautfarben je Rasse (19), 54 Haarfarben, Standard-Haarfarbe.
Rassen 1 Mensch, 2 Elf, 3 Zwerg, 4 Steinmensch, 5 Kindred, 6 Wolf; Geschlecht m / w.
