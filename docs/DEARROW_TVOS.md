# DeArrow auf TypeType tvOS (Experiment, 25.11.2026)

Branch: `feature/dearrow-tvos-20261125`. **Nicht** nach `main` übernommen, kein Pull Request.

## Server-API und Optionen

Die vorhandenen TypeType-Server-Endpunkte werden verwendet:
- `GET /api/settings`, `PUT /api/settings` für die Kontooptionen.
- `GET /api/dearrow?videoId=<11-Zeichen-ID>` für Titel-/Thumbnail-Kandidaten.
- `GET /api/dearrow/thumbnail?videoId=...&time=...` für ein gerendertes Thumbnail.

Die vier Optionen stehen unter **Einstellungen → Inhalte → DeArrow**:
- `deArrowEnabled` (standardmäßig `false`).
- `deArrowTitleMode`: `original`, `dearrow`.
- `deArrowThumbnailMode`: `original`, `dearrow`, `random`, `dearrow_or_random`.
- `deArrowTrustMode`: `accepted` (gesperrt oder votes >= 0), `locked` (nur locked).

Bei deaktiviertem DeArrow gibt es **keine** DeArrow-Metadatenanfragen. DeArrow ersetzt bei Aktivierung das Bild bzw. den Titel, nicht die Fallback-Kette. Fehlen vertrauenswürdige Kandidaten oder ist der Bilddownload fehlerhaft, bleibt das ursprüngliche TypeType-Thumbnail der zweite Versuch. Erst danach werden der TypeType-Proxy (HQ, MQ) und die direkten YouTube-URLs (HQ, MQ) probiert. Große Detailbilder versuchen weiterhin `maxresdefault`, `hq720`, `sddefault` vor HQ/MQ; ein DeArrow-Bild hat Vorrang.

Die Auswahl gilt für gemeinsame Videokarten (Home, History, Suche, Bibliothek, Abos, Kanäle, verwandte Videos), die Videodetails und native Top-Shelf-Snapshots. Top Shelf sendet keine DeArrow-Anfrage aus der Extension: die Haupt-App bereitet höchstens die fünf veröffentlichten Einträge vor und legt nur öffentliche URLs in den gemeinsamen UserDefaults ab.

## Performance

- **Off:** kein zusätzlicher Task für reguläre Kacheln, keine weitere HTTP-Anfrage.
- **On:** maximal eine `/api/dearrow`-Anfrage je sichtbarer YouTube-Video-ID und Konto-/Moduskombination pro positivem Cache-Zeitraum. Keine pro-Fokus-Requests oder Polling.
- Ein gemeinsamer, nach Konto/Server/Modus getrennter Cache fasst gleichzeitige Anfragen für gleiche Videos zusammen.
- Höchstens **3 aktive Netzwerkanfragen**, maximal **32 gleichzeitig ausstehende Lookups**. Negatives Resultat **90 s**, gültiges Resultat **3600 s**. Höchstens **192 abgeschlossene Einträge** im Speicher.
- Timeout: **8 s** je Branding-Metadatenrequest. tvOS-UI wartet nicht auf DeArrow und zeigt sofort reguläre Titel/Thumbnails.
- Top Shelf prüft bei neuen/metadatengeänderten Einträgen höchstens die veröffentlichten **5 Videos**, verwendet denselben DeArrow-Cache und startet erst anschließend die vorhandene Poster-Vorabprüfung. Keine zusätzlichen History-Requests.
- Originale Bilddecoder, vier parallele Thumbnail-Downloads, Bild-NSCache und Fokusnavigation bleiben unverändert.

## Grenzen, die vor Merge überprüft werden müssen

- Es gibt noch **keine Bestätigung durch einen physischen Apple-TV-Test**, dass die Serverversion in der eigenen Installation die Kandidaten in allen Konfigurationen liefert.
- TypeType liefert bei `/dearrow/thumbnail` unter Umständen selbst ein Fallback-Bild. Die tvOS-App kann am HTTP-200-Bild nicht erkennen, ob serverseitig ein originales Fallback statt des DeArrow-Frames zurückgegeben wurde.
- Der **Player-OSD und die Wiedergabe-Historienobjekte** behalten weiterhin den originalen Videotitel; Listen, Details und Top Shelf zeigen DeArrow-Titel. Die Kontodaten/History-Titel werden absichtlich nicht überschrieben.
- Kein zusätzliches Speichern lokaler Posterdateien und kein DeArrow-Direktzugriff auf `dearrow.ajay.app`.
- Die Servereinstellungen wirken nur, wenn ein verwendbares Konto-/Settings-API verfügbar ist. Gastzugriffe ohne Einstellungsdaten zeigen die Standardbilder.
- Für das Experiment werden Build/Unit/UI-Tests über einen Branch-spezifischen GitHub-Actions-Pushlauf benötigt. Der grüne Status wird erst nach tatsächlichem Erfolg dokumentiert.

## Gerätetest

1. Einstellungen → Inhalte → DeArrow einschalten; zunächst Titel `dearrow`, Bild `dearrow_or_random`, Vertrauen `accepted`.
2. Ein Video mit bekanntem DeArrow-Beitrag in Home, Verlauf, Suche, Details und Top Shelf öffnen. Titel/Bild sollten nach dem Hintergrundlookup wechseln, ohne Fokus- oder Scrollsprung.
3. Mit `locked` und `accepted` vergleichen; bei `original` getrennt Titel und Bild unverändert lassen. Bei fehlenden Kandidaten müssen die Originale bleiben.
4. TypeType-Bildendpunkt `/api/dearrow/thumbnail` künstlich scheitern lassen; zuerst Original, dann die bisherigen TypeType-Proxy-/YouTube-Fallbacks prüfen.
5. Einstellungen über einen zweiten Client ändern und Inhaltseinstellungen am Apple TV erneut öffnen; Werte müssen vom Server übernommen werden.
6. In langen Listen schnell scrollen: keine Fokusverzögerung, höchstens 3 parallele DeArrow-Metadatenanfragen; Top Shelf darf keine zusätzlichen History-Anfragen auslösen.

## Einstellungen: Fokus und störungsfreie Aktualisierung (25.11.2026)

- **Speichern ohne Layoutsprung:** Der asynchrone Save-Indikator liegt jetzt als Overlay über dem bestehenden Aktualisieren-Button. Das Ein-/Ausblenden fügt keinen neuen Eintrag in die vertikale ScrollView ein, sodass Inhaltskarten, Scrollposition und aktueller Fokus stabil bleiben sollen. Der bisherige einzelne Settings-PUT bleibt unverändert; Fehlerhinweise werden bei echten Fehlern weiterhin angezeigt.
- **Auswahl startet bei gespeichertem Wert:** Der `Picker(.menu)` unter tvOS fokussiert beim Öffnen nicht verlässlich den ausgewählten Eintrag. Für **Einstellungen → Inhalte** gibt es daher eine eigene SwiftUI-Auswahlansicht mit `@FocusState`, `.defaultFocus` und `ScrollViewReader`; sie fokussiert die aktuelle Option nativ ohne Timer, Reordering oder UIKit-Hack. Das gilt auch für die umfangreiche 0/50–100%-Auswahl des Wiedergabeschwellwertes. Andere Settings-Picker bleiben unverändert.
- **DeArrow ausgeschaltet:** Der Hauptschalter bleibt anwählbar; die drei darunterliegenden Einstellungen Titel/Bild/Vertrauen sind sichtbar, ausgegraut und deaktiviert. Die gewählten Werte bleiben gespeichert, bis DeArrow wieder eingeschaltet wird.
- **Performance:** Auswahloptionen sind statisch vorgehalten; die bis zu 52 fokussierbaren Elemente für den Wiedergabeschwellwert existieren erst im geöffneten Auswahlfenster. Kein Timer, keine neue Netzwerkanfrage, keine neuen globalen Fokus-Observer.
- **UI-Regressionschecks:** Debug-Vorschau für einen nicht ersten Auswahlwert (75 %), automatischer Siri-Remote-Fokus auf diesen Wert und gesperrte DeArrow-Unteroptionen. Simulator-/Hardware-Fokusverhalten muss über die Tests und auf dem Apple TV bestätigt werden.

## DeArrow-Markierung und lokale Ressourcen

- Das offizielle DeArrow-Logo stammt aus dem upstream-Repository `ajayyy/DeArrow`, `public/icons/logo.svg` und `public/icons/logo-128.png`.
- Das 128-px-PNG liegt in `TypeTypeTV/Assets.xcassets/DeArrowLogo.imageset/`. Die SVG-Originaldatei und die CC-BY-4.0-Attribution liegen unter `docs/third-party/`; keine Laufzeit-Netzwerkzugriffe für die Kennzeichnung.
- Die App zeigt auf erfolgreich geladenen DeArrow-Thumbnails ein dezentes **18-pt-Logo links oben** mit halbtransparentem Hintergrund. Es ist an die tatsächlich verwendete Bildquelle gebunden: bei Fallback zum normalen TypeType-/YouTube-Bild bleibt es unsichtbar. Bei Mitgliedervideos wird die Kennzeichnung unter das bereits dort befindliche Mitglieder-Badge versetzt, damit sie nicht verdeckt wird.
- Der DeArrow-Einstellungsblock verwendet dasselbe lokale Logo **28 pt links neben der Überschrift**. Nur dieser Block trägt es; andere Einstellungen bleiben unverändert.
- Die native Top-Shelf-Extension erhält aktuell eine öffentliche Bild-URL, aber keine fertig zusammengesetzte Bilddatei. Daher erscheint die DeArrow-Kennzeichnung **noch nicht als zusätzliches Overlay auf dem tvOS-Home-Screen-Top-Shelf-Poster**; dazu wäre eine gesonderte, zusammengesetzte Bildquelle erforderlich.
