# Normalisiertes Schema (Stand M1)

Alle Adapter liefern dasselbe Format. Code: `server/src/sources/`.
Konsens, Spannbreite und das Gesamt-`Forecast` aus plan.md §3 folgen mit M2.

## Einheiten und Zeit

- °C, mm, km/h, hPa, Prozent als 0–100, Windrichtung in Grad (woher der Wind kommt).
- Zeitstempel: RFC 3339 in UTC (`2026-11-09T11:00:00Z`), Datum: `JJJJ-MM-TT` in Europe/Berlin.
- **Stundenkonvention:** `at` ist der Beginn der Stunde. Momentanwerte (Temperatur, Wind,
  Wolken, Druck) gelten zu `at`; Niederschlag, Niederschlagswahrscheinlichkeit und
  `condition` beschreiben `at` bis `at + 1 h`. Open-Meteo und Bright Sky stempeln Summen mit
  dem Ende der Stunde – deren Adapter verschieben sie um eine Stunde nach vorn.
- Fehlt einer Quelle ein Pflichtwert, fällt die Stunde bzw. der Tag dieser Quelle weg.
  Es wird nie mit 0 aufgefüllt.

## Typen

```text
SourceId     weatherkit | open_meteo:icon_d2 | open_meteo:icon_eu | open_meteo:ecmwf_ifs
             | open_meteo:gfs | bright_sky:mosmix | pirate_weather

Condition    clear | partly_cloudy | cloudy | fog | drizzle | rain | heavy_rain
             | snow | sleet | hail | thunderstorm | wind

HourPoint    at, temp_c, feels_like_c?, precip_mm, precip_prob_pct?, wind_kmh,
             gust_kmh?, wind_dir_deg?, cloud_pct?, humidity_pct?, pressure_hpa?,
             condition, is_day?

DayPoint     date, temp_min_c, temp_max_c, precip_mm, precip_prob_pct?,
             wind_max_kmh?, gust_max_kmh?, condition, sunrise?, sunset?

SourceData   source, hourly: [HourPoint], daily: [DayPoint]
```

`?` = darf `null` sein. Gegenüber plan.md §3 sind `is_day` und `wind_max_kmh` optional:
Bright-Sky-Symbole wie `cloudy` sagen nichts über Tag/Nacht, und WeatherKit sowie
Pirate Weather liefern pro Tag nur einen mittleren Wind, keinen Höchstwert.

`heavy_rain` = Regen ab 7,6 mm/h (WMO-Schwelle), sofern die Quelle es nicht selbst meldet.
Tages-`condition` aus Stunden (Bright Sky): ab 1 mm Tagessumme der heftigste Niederschlag,
sonst die häufigste trockene Bedingung.

## Quellen

| SourceId | Upstream | Stunden | Tage | Besonderheiten |
|---|---|---|---|---|
| `open_meteo:icon_d2` | Open-Meteo `dwd_icon_d2_native` | ≈ 48 h | 1–2 | `dwd_icon_d2` endet am 30.11.2026 |
| `open_meteo:icon_eu` | Open-Meteo `dwd_icon_eu_native` | ≈ 5 Tage | ≈ 5 | |
| `open_meteo:ecmwf_ifs` | Open-Meteo `ecmwf_ifs` (IFS HRES 9 km) | 10 Tage | 10 | ab +90 h dreistündlich vom Modell, Open-Meteo interpoliert |
| `open_meteo:gfs` | Open-Meteo `ncep_gfs_global` (0,11°) | 10 Tage | 10 | nicht `gfs_seamless` (enthält HRRR, endet 30.11.2026) |
| `bright_sky:mosmix` | Bright Sky `/weather`, nur Quellen vom Typ `forecast` | ≈ 10 Tage | nur vollständige Ortstage | Tage selbst aggregiert, kein Sonnenauf-/-untergang |
| `weatherkit` | `/api/v1/weather/de/…`, `forecastHourly` (50 h) + `forecastDaily` | 50 h | 10 | Feuchte/Wolken/Chance 0–1 → %; Tag ohne Wind-Maximum |
| `pirate_weather` | `/forecast/{key}/…?units=ca` | 48 h | 7 (Tag 0 entfällt) | Niederschlag aus `precipIntensity` (`precipAccumulation` ist cm und mischt Schnee) |

**Open-Meteo und Zeitumstellung:** Open-Meteo wendet einen festen UTC-Offset auf die ganze
Antwort an (den zum Abrufzeitpunkt gültigen). Tagesdaten jenseits einer Zeitumstellung
umfassen daher 01–01 bzw. 23–23 Uhr Ortszeit. Das Datum wird über `utc_offset_seconds`
bestimmt und stimmt immer.

## API (M1)

| Methode | Pfad | |
|---|---|---|
| `GET` | `/api/v1/places` | Orte |
| `POST` | `/api/v1/places` | `{"name","lat","lon"}` → 201; braucht `X-Witterung-Client` bei Cookie-Anmeldung |
| `GET` | `/api/v1/places/{id}/raw` | `place`, `providers[]` (`configured`, `state`, `quota`), `sources[]` (`source`, `fetched_at`, `stale`, `hourly`, `daily`), `attribution[]` |

`stale` = älter als 3 h. `state.error = "quota"` heißt: Limit erreicht, es bleibt der letzte Stand.

## Abruf und Kontingente

| Provider | Takt | Kontingent | Grenze (50 %) | Kosten pro Abruf |
|---|---|---|---|---|
| `open_meteo` | 60 min | 10.000/Tag | 5.000/Tag | 8,4 (21 Variablen × 4 Modelle / 10; Header `X-RateLimit-Cost` bestätigt) |
| `bright_sky` | 60 min | eigene Obergrenze 6.000/Tag | 3.000/Tag | 1 |
| `weatherkit` | 15 min | 500.000/Monat | 250.000/Monat | 1 |
| `pirate_weather` | 60 min | 10.000/Monat | 5.000/Monat | 1 |

Perioden in UTC. Gebucht wird vor dem Abruf; Fehlversuche zählen mit. Nach einem Fehler
Backoff 1, 2, 4 … min, höchstens bis zum Takt. Der Abrufzustand liegt in SQLite, ein Neustart
löst keinen Abruf aus.
