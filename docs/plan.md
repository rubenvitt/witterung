# Witterung – Plan v0.1

Persönliche Wetter-App als Ersatz für Carrot Weather: ein Aggregator auf dem Homelab
kombiniert Apple WeatherKit, Open-Meteo (mehrere Modelle), Bright Sky/DWD und Pirate
Weather, zeigt Konsens und Spannbreite und beliefert eine SwiftUI-App mit Widgets.

Stand: freigegeben am 09.11.2026 (Entscheidungen in Abschnitt 8).

## 1. Vorab geprüft (09.11.2026)

| Befund | Folge |
|---|---|
| Open-Meteo markiert `dwd_icon_d2`, `dwd_icon_eu`, `dwd_icon_global` als **„Discontinued 2026-11-30“**. Nachfolger: `dwd_icon_d2_native`, `dwd_icon_eu_native`, `dwd_icon_global_native` (plus `dwd_icon_d2_ruc_native`). | Von Anfang an die `*_native`-IDs nutzen. Testabruf für Uelzen mit `dwd_icon_d2_native,dwd_icon_eu_native,ecmwf_ifs025,gfs_seamless` in **einem** Request funktioniert; Antwortfelder tragen das Modell als Suffix (`temperature_2m_dwd_icon_d2_native`). |
| Open-Meteo, nicht-kommerziell: < 10.000 Calls/Tag, 5.000/h, 600/min. Requests mit mehr als 10 Variablen oder mehr als 2 Wochen zählen anteilig mehrfach; mehrere Modelle zählen ebenfalls mit. | Quotenrechnung mit Gewicht pro Request (siehe 4.), nicht mit Request-Anzahl. |
| Bright Sky: `/current_weather` findet für Uelzen die SYNOP-Station 05146 „Uelzen“ (3,8 km). `/alerts` liefert die Warnzelle 803360025 „Stadt Uelzen“. `/radar?lat&lon&distance` liefert 25 Frames à 5 min inkl. 2 h Nowcast. Endpunkte: `/weather`, `/current_weather`, `/synop`, `/radar`, `/alerts`, `/sources`. | Bright Sky deckt Beobachtung, MOSMIX, Radar-Nowcast und Warnungen ab. Radar ist polarstereografisch und muss für Kartenoverlays umprojiziert werden (erst Meilenstein 5). |
| Pirate Weather: Free-Tier **10.000 Calls/Monat**. | Nur stündlich, nur gespeicherte Orte (siehe 4.). |
| WeatherKit: 500.000 Calls/Monat in der Developer-Mitgliedschaft. Pflicht: Apple-„Weather“-Marke anzeigen plus Link auf die Datenquellen-Attribution; Warnungstexte unverändert; abgeleitete Werte als „verändert“ kennzeichnen. Minutenregen nur in „ausgewählten Regionen“. | Ob `forecastNextHour` für Deutschland kommt, prüft Meilenstein 1 über den Availability-Endpunkt. Fallback ist ohnehin der DWD-Radar-Nowcast. Warnungen kommen ausschließlich vom DWD (vermeidet Doppelung und WeatherKit-Warnauflagen). |

## 2. Repo-Struktur

Ein Repo, ein Rust-Crate, eine Xcode-App. Kein Workspace-Gerüst auf Vorrat.

```
witterung/
├── README.md                 # Setup, Secrets, Quotenrechnung, Attribution, Skizze
├── docs/
│   ├── plan.md               # dieses Dokument
│   ├── schema.md             # API-Vertrag (ab M1, aus Abschnitt 3)
│   └── adr/0001-backend-stack.md
├── server/                   # Rust: axum, sqlx/SQLite, reqwest
│   ├── Cargo.toml
│   ├── migrations/
│   ├── src/
│   │   ├── main.rs, app.rs, config.rs, db.rs
│   │   ├── auth/             # aus zunder übernommen: Pocket ID + Geräte-Token
│   │   ├── model.rs          # normalisiertes Schema
│   │   ├── consensus.rs      # Median, Spannbreite, Regen-Konsens
│   │   ├── quota.rs          # Budget pro Quelle, TTL, Durchsetzung
│   │   ├── poller.rs         # Abrufplan pro Quelle und Ort
│   │   ├── sources/          # ein Adapter je Quelle
│   │   │   ├── weatherkit.rs
│   │   │   ├── open_meteo.rs
│   │   │   ├── bright_sky.rs
│   │   │   └── pirate_weather.rs
│   │   └── api/              # /api/v1/..., /health
│   └── tests/fixtures/<quelle>/*.json   # aufgezeichnete Antworten
├── ios/
│   └── Witterung.xcodeproj   # App + Widget-Extension, App Group für Cache und Token
├── deploy/
│   ├── Dockerfile
│   ├── compose.yaml          # Traefik-Labels, Secrets
│   └── .env.example
└── .github/workflows/ci.yml  # Tests, Image amd64 + arm64 nach GHCR
```

Die Webapp (Meilenstein 7) liegt später als statische Seite unter `web/` und wird vom
Server ausgeliefert.

## 3. Normalisiertes Schema

Einheiten metrisch, intern immer: °C, mm bzw. mm/h, km/h, hPa, %, Grad. Zeitstempel in der
API als RFC 3339 in UTC; Europe/Berlin nur für Tagesgrenzen (`daily`) und die Anzeige.
Die Adapter rechnen um (Pirate Weather liefert z. B. m/s mit `units=si`).

```text
SourceId        "weatherkit" | "open_meteo:icon_d2" | "open_meteo:icon_eu"
                | "open_meteo:ecmwf_ifs" | "open_meteo:gfs" | "bright_sky:mosmix"
                | "pirate_weather"

Condition       clear | partly_cloudy | cloudy | fog | drizzle | rain | heavy_rain
                | snow | sleet | hail | thunderstorm | wind

HourPoint       temp_c, feels_like_c?, precip_mm, precip_prob_pct?, wind_kmh,
                gust_kmh?, wind_dir_deg?, cloud_pct?, humidity_pct?, pressure_hpa?,
                condition, is_day?

DayPoint        date (Europe/Berlin), temp_min_c, temp_max_c, precip_mm,
                precip_prob_pct?, wind_max_kmh?, gust_max_kmh?, condition,
                sunrise?, sunset?

Spread          { min, max } je numerischer Größe; precip_agreement_pct
                = Anteil der Quellen mit ≥ 0,1 mm in dieser Stunde

SourceStatus    source, ok, fetched_at?, valid_until?, stale, error?,
                quota { used, budget, period }

Forecast        location { id, name, lat, lon, kind: saved|current }
                generated_at
                sources: [SourceStatus]
                now: { observed?: { station, distance_m, at, temp_c, ..., condition },
                       forecast: HourPoint (Konsens) }
                nowcast: [{ at, precip_mm_h, source }]        # 2 h, 5 min (Radar)
                hourly: [{ at, n_sources, consensus: HourPoint, spread: Spread,
                           by_source: { SourceId: HourPoint } }]   # 48 h
                daily:  [{ date, n_sources, consensus: DayPoint, spread: Spread,
                           by_source: { SourceId: DayPoint } }]    # 10 Tage
                alerts: [{ id, severity, event, headline, description,
                           instruction?, onset, expires?, source: "dwd" }]
                attribution: [{ source, text, url }]
```

Konsens = Median je Größe über alle verfügbaren Quellen (robust gegen einen Ausreißer),
Bedingung = häufigste. Keine Gewichtung im MVP; die kommt erst, wenn der Rückblick
(„Wie gut lag welche Quelle?“) Daten hat.

Die Quellen reichen unterschiedlich weit (ICON-D2 ≈ 48 h, ICON-EU ≈ 5 Tage, die übrigen
bis 10 Tage). Jede Zeile trägt deshalb `n_sources`; eine schmale Spannbreite in Tag 8 aus
drei Quellen soll nicht so aussehen wie eine aus sieben. Open-Meteo liefert jenseits der
Modellreichweite `null` – der Adapter lässt die Quelle dann weg, statt 0 zu setzen.

> **Nachtrag M1 (09.11.2026):** Genaues Format in [schema.md](schema.md). Abweichungen:
> `is_day` und `wind_max_kmh` sind optional; GFS kommt als `ncep_gfs_global` (nicht
> `gfs_seamless`, das HRRR enthält und am 30.11.2026 endet); Open-Meteo rechnet mit einem
> festen UTC-Offset über die Zeitumstellung hinweg. Open-Meteo-Kosten gemessen: 8,4 pro Abruf.

## 4. Quellen, Abrufplan und Quoten

Annahme: 3 gespeicherte Orte + 1 aktueller Standort = 4 Orte. Den Standort rundet der
Server auf ein Raster von 0,02° (≈ 2 km), damit kleine Bewegungen den Cache treffen;
er wird nur abgefragt, solange die App ihn in den letzten 24 h gemeldet hat.

| Quelle | Endpunkt | Takt | Last | Kontingent | Auslastung |
|---|---|---|---|---|---|
| WeatherKit | REST, ein Request mit `currentWeather,forecastHourly,forecastDaily,forecastNextHour` | 15 min | 4 × 96 × 30 ≈ 11.500/Monat | 500.000/Monat | ≈ 2 % |
| Open-Meteo | `/v1/forecast`, 4 Modelle, ~20 Variablen, 10 Tage → Gewicht ≈ 8 | 60 min | 4 × 24 × 8 ≈ 770/Tag | 10.000/Tag | ≈ 8 % |
| Pirate Weather | `/forecast`, nur gespeicherte Orte | 60 min | 3 × 24 × 30 ≈ 2.160/Monat | 10.000/Monat | ≈ 22 % |
| Bright Sky | `/weather` (MOSMIX) 60 min, `/current_weather` 10 min, `/alerts` 5 min, `/radar` 5 min | – | 4 × (24 + 144 + 288 + 288) ≈ 3.000/Tag | kein festes Kontingent (Fair Use) → eigene Obergrenze 6.000/Tag | Grenze im Code: 50 % der eigenen Obergrenze = 3.000/Tag. Deshalb ab M2 Radar und Warnungen **einmal für alle Orte** abrufen (Bounding Box bzw. Warnzellen), nicht je Ort |

Durchsetzung im Code (`quota.rs`): jede Quelle hat Budget und Periode als Konstante,
der Zähler steht in SQLite. Vor jedem Abruf wird gewichtet gebucht; ist die 50-%-Grenze
der Periode erreicht, liefert der Server den letzten Stand mit `stale: true` und
`error: "quota"`. Ein manueller Refresh aus der App löst keinen Abruf am Budget vorbei aus.

Fällt eine Quelle aus, wird das geloggt, erscheint in `sources[]` und `/health`, und der
Konsens rechnet mit den übrigen. Kein Retry-Sturm: exponentielles Backoff bis maximal
zum regulären Takt.

## 5. Betrieb und Anmeldung

- Image `ghcr.io/rubenvitt/witterung` für linux/amd64 und linux/arm64 (CI-Muster aus zunder).
- Compose mit Traefik-Labels; Daten in `./data` (SQLite).
- Web: Pocket ID per OIDC (wie zunder). App und Widget: Geräte-Token per OAuth
  Authorization Code mit PKCE (Anmeldung im Browser über Pocket ID, Token läuft nicht ab,
  in der Weboberfläche widerrufbar). Der Token liegt im Schlüsselbund mit App-Group-Zugriff,
  damit das Widget ohne App-Start abrufen kann.
- `/health` ist ohne Anmeldung erreichbar, zeigt aber nur `ok`; die Detailansicht pro
  Quelle (letzter Erfolg, letzter Fehler, Quote) braucht Anmeldung.
- Secrets: WeatherKit-`.p8` als Docker-Secret-Datei, WeatherKit-Key-ID/Team-ID/Service-ID
  und Pirate-Weather-Key in `.env` (nie im Repo). Orte und alles andere stellt man in der
  App ein, nicht per Env.

## 6. Meilensteine

Jeder Meilenstein endet mit einem lauffähigen, getesteten, gepushten Stand.

| # | Inhalt | Fertig, wenn |
|---|---|---|
| M0 | Gerüst: axum-Server, SQLite-Migrationen, Auth aus zunder, `/health`, Dockerfile, Compose, CI mit arm64-Image | `docker compose up` auf dem Homelab, hinter Traefik, Login über Pocket ID |
| M1 | Vier Adapter mit Fixture-Tests, Quota-Modul, Poller, `/api/v1/places/{id}/raw`. Bright-Sky-Parser und Fixtures aus `lagemonitor` (`src/sources/weather.rs`) als Ausgangspunkt. Prüfen: WeatherKit-Availability für Uelzen (Minutenregen?), Pirate-Weather-Registrierung ohne Kreditkarte | jede Quelle liefert normalisierte `HourPoint`/`DayPoint`; Ausfall einer Quelle bricht nichts; `docs/schema.md` steht |
| M2 | Aggregation: Konsens, Spannbreite, `now` aus SYNOP + Prognose, Nowcast 2 h, DWD-Warnungen, Orte-Verwaltung, `/health` mit Quoten | `/api/v1/places/{id}/forecast` liefert das Schema aus Abschnitt 3 vollständig |
| M3 | iOS-App: Anmeldung, Orte + Standort, Jetzt, 48 h, 10 Tage, Nowcast-Diagramm, Warnungen, Quellenvergleich, Offline-Cache, Attributionsseite | MVP-Umfang für Uelzen auf dem iPhone korrekt |
| M4 | Widgets: Home + Lockscreen, Temperatur, Symbol, Regenhinweis; Timeline aus dem Cache. Prüfen: Muss die Apple-Weather-Kennzeichnung auch ins Widget? | Widget aktualisiert sich ohne App-Start → **MVP fertig**, README komplett |
| M5 | Regenradar-Karte mit Zeitleiste. Erst prüfen: `lagemonitor` nutzt den DWD-GeoServer-WMS (`maps.dwd.de`, Layer `dwd:Niederschlagsradar`) in Web-Mercator – das spart die Umprojektion; offen ist, ob der WMS eine Zeitdimension inkl. Nowcast hat | soll |
| M6 | ntfy auf dem Server aufsetzen; Push: Warnung neu, Regenbeginn in < 30 min | soll |
| M7 | Webapp (schlanke Ansicht derselben API) | soll |
| später | Watch, Pollen/Luftqualität, Prognose-Archiv und Quellen-Rückblick | kann |

## 7. Risiken (Pre-Mortem: „Ein Jahr später nutze ich wieder Carrot – warum?“)

1. **Das MVP war zu groß und blieb nach M2 liegen.** Gegenmittel: M0–M2 sind schon
   allein nützlich (API im Browser), M3 beginnt mit nur einer Ansicht. Carrot läuft
   parallel weiter, bis das Kündigungskriterium aus Abschnitt 8 erfüllt ist.
2. **Xcode-/iOS-Updates brechen App und Widget.** Gegenmittel: keine Drittabhängigkeiten
   in der App, nur SwiftUI, WidgetKit, Swift Charts, MapKit.
3. **Eine Quelle ändert ihre API still** (siehe ICON-D2-Abschaltung). Gegenmittel:
   Fixture-Tests, Quellenstatus im UI, `/health` meldet Ausfälle; Push über ntfy auf mich.
4. **WeatherKit hat für Deutschland keinen Minutenregen.** Dann trägt der DWD-Nowcast
   allein; der Plan hängt nicht daran.
5. **Konsens wirkt präziser, als er ist.** Gegenmittel: Spannbreite ist immer sichtbar,
   nicht nur der Median.

## 8. Entscheidungen (09.11.2026)

1. **Domain:** `witterung.rubeen.dev`, öffentlich hinter Pocket ID (Empfehlung übernommen,
   nicht ausdrücklich bestätigt).
2. **ntfy:** gibt es noch nicht; M6 setzt ntfy auf dem Server neu auf.
3. **Secrets:** wie vorgeschlagen – Quellen-Zugänge als Secrets, alles andere in der App.
4. **Carrot kündigen, wenn:** „die App liefert korrektes Wetter und ist wirklich usable
   mit sehr guter UX“.
5. **Warnungen:** ausschließlich vom DWD.
