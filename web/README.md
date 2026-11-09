# Witterung – Web-App (M7)

Statische Single-Page-App ohne Build-Schritt: Vanilla-JS-ES-Module, Hash-Routing, Diagramme als
SVG. Der Server bettet die Dateien ein und liefert sie aus:

| Pfad | Datei |
|---|---|
| `/` | `web/index.html` |
| `/assets/<datei>` | `web/assets/<datei>` (flach, keine Unterordner; `.js` als `text/javascript`) |

Ansichten: `#/wetter/<ort>`, `#/vergleich/<ort>`, `#/radar/<ort>`, `#/verwaltung`; `<ort>` ist die
ID eines gespeicherten Orts oder `hier` (Browser-Standort → `/api/v1/forecast?lat&lon`).

- **Anmeldung:** Sitzungs-Cookie, schreibende Anfragen mit `X-Witterung-Client: web`. Bei 401 geht
  es nach `/auth/login?return_to=<Pfad + Hash>`, Abmelden per `POST /auth/logout`.
- **CSP:** keine Inline-Skripte, -Styles oder -Handler. Läuft mit
  `default-src 'self'; img-src 'self' data: https://maps.dwd.de https://*.tile.openstreetmap.org; connect-src 'self'`.
  Dynamische Breiten und Drehungen setzt der Code per CSSOM (`el.style.x = …`), das erlaubt die CSP.
- **Leaflet 1.9.4** liegt unverändert in `assets/` (`leaflet.js`, `leaflet.css`, Lizenz
  `LICENSE-leaflet.txt`, BSD-2-Clause). Marker-Bilder braucht die App nicht.
- **Attribution:** Fußzeile aus `attribution[]` der Vorhersage (Open-Meteo mit CC-BY-4.0-Link,
  DWD/Bright Sky, Apple Weather mit Link zu den Datenquellen nur bei WeatherKit-Daten, Pirate
  Weather); Radar: OpenStreetMap-Mitwirkende und Deutscher Wetterdienst.

## Lokal ausprobieren

```fish
python3 web/dev/mock-server.py --port 8765   # --unauth: startet abgemeldet
open http://localhost:8765/
```

Der Mock (nur Python-Standardbibliothek) bildet jeden Endpunkt aus `docs/api.md` mit Daten im
Speicher nach, verlangt den Client-Header bei Schreibzugriffen (sonst 403) und schickt die CSP oben
mit. `web/dev/mock-forecast.json` ist eine Novemberlage für Uelzen (Kaltfront mit Regen in
≈ 25 min, Sturmböen-Warnung, Pirate Weather mit Fehler, MOSMIX veraltet); der Mock verschiebt
die Zeitstempel auf „jetzt“. Neu erzeugen: `python3 web/dev/gen-mock-forecast.py`.
Radarbilder und Kartenkacheln kommen auch im Mock live vom DWD bzw. von OpenStreetMap.
