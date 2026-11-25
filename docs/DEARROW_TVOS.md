# DeArrow auf TypeType tvOS (Integration, 25.11.2026)

Entwicklungsbranch: `feature/dearrow-tvos-20261125`. Am 25.11.2026 nach Tests und Bereinigung ohne Pull Request nach `main` übernommen.

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

## Bekannte Grenzen und weitere Geräteprüfungen

- Ein physisches Apple TV bestätigte die alternativen DeArrow-Titel und Bild-URLs. Nicht alle Modi und die erfolgreiche Erzeugung eines tatsächlich anderen Videoframes wurden auf Hardware überprüft.
- TypeType liefert bei `/dearrow/thumbnail` unter Umständen selbst ein Fallback-Bild. Die tvOS-App kann am HTTP-200-Bild nicht erkennen, ob serverseitig ein originales Fallback statt des DeArrow-Frames zurückgegeben wurde.
- Der **SABR-Player-OSD** zeigt jetzt ebenfalls den DeArrow-Titel, wenn eine aktuelle und vertrauenswürdige Titelvariante verfügbar ist. Die Kontodaten, der Verlauf, Now Playing, die Videoidentität und die Wiedergabefortschritte behalten den ursprünglichen Server-Titel. Das native HLS-System-OSD wird durch die Änderung nicht angepasst.
- Kein zusätzliches Speichern lokaler Posterdateien und kein DeArrow-Direktzugriff auf `dearrow.ajay.app`.
- Die Servereinstellungen wirken nur, wenn ein verwendbares Konto-/Settings-API verfügbar ist. Gastzugriffe ohne Einstellungsdaten zeigen die Standardbilder.
- Der letzte vollständige CI-Lauf vor den Testkorrekturen bestätigte Simulator-/Geräte-Debug-/Release-Build sowie 57 UI-Tests. Thumbnail-Unit-Test-Fixtures und URL-Erwartungen wurden korrigiert; der abschließende Folgelauf muss separat erfolgreich sein.

## Gerätetest

1. Einstellungen → Inhalte → DeArrow einschalten; zunächst Titel `dearrow`, Bild `dearrow_or_random`, Vertrauen `accepted`.
2. Ein Video mit bekanntem DeArrow-Beitrag in Home, Verlauf, Suche, Details und Top Shelf öffnen. Titel/Bild sollten nach dem Hintergrundlookup wechseln, ohne Fokus- oder Scrollsprung.
3. Mit `locked` und `accepted` vergleichen; bei `original` getrennt Titel und Bild unverändert lassen. Bei fehlenden Kandidaten müssen die Originale bleiben.
4. TypeType-Bildendpunkt `/api/dearrow/thumbnail` künstlich scheitern lassen; zuerst Original, dann die bisherigen TypeType-Proxy-/YouTube-Fallbacks prüfen.
5. Einstellungen über einen zweiten Client ändern und Inhaltseinstellungen am Apple TV erneut öffnen; Werte müssen vom Server übernommen werden.
6. In langen Listen schnell scrollen: keine Fokusverzögerung, höchstens 3 parallele DeArrow-Metadatenanfragen; Top Shelf darf keine zusätzlichen History-Anfragen auslösen.

## Einstellungen: Fokus und störungsfreie Aktualisierung (25.11.2026)

- **Speichern ohne Layoutsprung:** Der asynchrone Save-Indikator liegt jetzt als Overlay über dem bestehenden Aktualisieren-Button. Das Ein-/Ausblenden fügt keinen neuen Eintrag in die vertikale ScrollView ein, sodass Inhaltskarten, Scrollposition und aktueller Fokus stabil bleiben sollen. Der bisherige einzelne Settings-PUT bleibt unverändert; Fehlerhinweise werden bei echten Fehlern weiterhin angezeigt.
- **Native Picker wiederhergestellt:** Alle Dropdowns unter **Einstellungen → Inhalte** nutzen wieder den ursprünglichen SwiftUI-`Picker(.menu)`. Das Öffnen beginnt auf tvOS gegebenenfalls beim obersten Menüeintrag; das frühere selbstgebaute Auswahl-Sheet und seine Fokus-Preview wurden auf Nutzerwunsch entfernt. Die dynamischen Einstellungen selbst behalten ihre ursprüngliche native Fokussteuerung.
- **DeArrow ausgeschaltet:** Der Hauptschalter bleibt anwählbar; die drei darunterliegenden Einstellungen Titel/Bild/Vertrauen sind sichtbar, ausgegraut und deaktiviert. Die gewählten Werte bleiben gespeichert, bis DeArrow wieder eingeschaltet wird.
- **Performance:** Keine eigene Auswahlansicht, kein zusätzlicher Fokusstatus, kein Timer, keine neue Netzwerkabfrage und keine neuen globalen Fokus-Observer. Die ursprünglichen Optionen des nativen Pickers werden wie vor der Sheet-Änderung verwaltet.
- **UI-Regressionschecks:** Bestehender nativer Fokus-/Refresh-Test und gesperrte DeArrow-Unteroptionen; die 75%-Fokussierung und deren Debug-Preview wurden zusammen mit der eigenen Auswahlansicht entfernt. Die native Menüauswahl auf dem Apple TV muss geprüft werden.

## DeArrow-Markierung und lokale Ressourcen

- Das offizielle DeArrow-Logo stammt aus dem upstream-Repository `ajayyy/DeArrow`, `public/icons/logo.svg` und `public/icons/logo-128.png`.
- Das 128-px-PNG liegt in `TypeTypeTV/Assets.xcassets/DeArrowLogo.imageset/`. Die SVG-Originaldatei und die CC-BY-4.0-Attribution liegen unter `docs/third-party/`; keine Laufzeit-Netzwerkzugriffe für die Kennzeichnung.
- Die App zeigt auf erfolgreich geladenen DeArrow-Thumbnails ein dezentes **18-pt-Logo links oben** mit halbtransparentem Hintergrund. Es ist an die tatsächlich verwendete Bildquelle gebunden: bei Fallback zum normalen TypeType-/YouTube-Bild bleibt es unsichtbar. Bei Mitgliedervideos wird die Kennzeichnung unter das bereits dort befindliche Mitglieder-Badge versetzt, damit sie nicht verdeckt wird.
- Der DeArrow-Einstellungsblock verwendet dasselbe lokale Logo **28 pt links neben der Überschrift**. Nur dieser Block trägt es; andere Einstellungen bleiben unverändert.
- Die native Top-Shelf-Extension erhält aktuell eine öffentliche Bild-URL, aber keine fertig zusammengesetzte Bilddatei. Daher erscheint die DeArrow-Kennzeichnung **noch nicht als zusätzliches Overlay auf dem tvOS-Home-Screen-Top-Shelf-Poster**; dazu wäre eine gesonderte, zusammengesetzte Bildquelle erforderlich.

## DeArrow-Bilder: schwarze Balken und Server-Fallback (25.11.2026)

Im Apple-TV-Gerätetest traten bei drei DeArrow-Bildadressen links und rechts schwarze Balken auf. Das ist **kein Effekt des kleinen Logo-Overlays**. Der TypeType-Server `DeArrowService.thumbnail()` liefert bei fehlgeschlagener Frame-Erstellung stattdessen `https://i.ytimg.com/vi/{videoId}/hqdefault.jpg` über *dieselbe* `/api/dearrow/thumbnail`-Adresse zurück. Ein 480×360-YouTube-Bild mit intern letterboxed 16:9-Inhalt wird bei `aspectRatio(.fit)` in der 16:9-Karte mit sichtbaren Balken angezeigt.

Der sichtbare DeArrow-Thumbnail-Pfad wird deshalb nur in normalen **16:9-Videokarten** mit SwiftUI `aspectRatio(.fill)` statt `.fit` gerendert und auf die Kartengrenzen beschnitten; die Originale und normalen Fallbacks bleiben `.fit`. Das skaliert das Bild proportional, erzeugt keine zusätzliche HTTP-Anfrage und ändert den Thumbnail-Decoder oder Bildcache nicht. Die Heroansicht nutzt bereits `.fill`.

**Noch offen:** Die TypeType-Server-Antwort zeigt den Fallback-Status derzeit nicht ausdrücklich als Header an. Der Client kann folglich aus dem URL-Pfad nicht eindeutig feststellen, ob ein Original-YouTube-Bild statt eines erzeugten DeArrow-Frames zurückkam. Die kleine DeArrow-Markierung bedeutet daher vorerst: *Bild über den DeArrow-Endpunkt geladen*, nicht beweisbar *Frame erfolgreich generiert*. Eine später ergänzte eindeutige Server-Kennzeichnung wäre für die präzise Badge-Anzeige sinnvoll. Ebenfalls auf Hardware nachtesten: ob sämtliche 4:3-Fallbackbilder ohne relevante Ausschnittverluste gerendert werden.

## SABR-Player-OSD: DeArrow-Titel (25.11.2026)

- SABR zeigt bei aktivierter DeArrow-Titelauswahl und einem geeigneten Kandidaten den DeArrow-Titel im vorhandenen OSD. Während eine nicht gecachte Antwort noch aussteht, bleibt der Originaltitel ohne Wiedergabeverzögerung sichtbar.
- Bei einem Video mit bereits in Listen/Details geladenen Branding-Daten wird **derselbe** konten-/server-/modusabhängige `TVDeArrowCache` verwendet: **kein** zusätzlicher Netzwerkaufruf. Bei einem kalten Direktstart kann höchstens eine Metadatenabfrage durch den vorhandenen deduplizierten, auf drei gleichzeitige Requests begrenzten Cache erfolgen. Bei ausgeschaltetem DeArrow gibt es **keinen** zusätzlichen Branding-Request.
- Die Änderung greift ausschließlich in die Textanzeige des SwiftUI-SABR-OSD ein; die Original-Metadaten für Playlist, History, Status/Presence und Now Playing bleiben unverändert. Wird das Konto, Video oder der Titelmodus gewechselt, wird ein alter DeArrow-Titel nicht in einen anderen Auswahlkontext übernommen.
- Der native HLS-Player verwendet Apples AVPlayerViewController-OSD und bleibt unverändert.
