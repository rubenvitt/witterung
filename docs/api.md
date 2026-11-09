# API v1 (Vertrag für App und Web, Stand M2)

Basis: `https://witterung.rubeen.dev`. JSON, UTF-8. Zeitpunkte RFC 3339 UTC, Daten
`JJJJ-MM-TT` (Europe/Berlin). Einheiten wie in [schema.md](schema.md): °C, mm, mm/h, km/h,
hPa, Prozent 0–100, Grad. Fehler: `{"error":{"code":"…","message":"…"}}` mit HTTP-Status.

## Anmeldung

**Browser (Web):** Sitzungs-Cookie über `/auth/login?return_to=/…` (Pocket ID). Schreibende
Anfragen mit Cookie brauchen den Header `X-Witterung-Client: web`.

**App (Gerät):** OAuth-ähnlicher Ablauf mit PKCE, ergibt ein langlebiges Bearer-Token.

1. App erzeugt `verifier` (43–128 Zeichen, `[A-Za-z0-9-._~]`) und
   `challenge = BASE64URL(SHA256(verifier))` ohne Padding.
2. App öffnet in `ASWebAuthenticationSession` (Callback-Schema `witterung`):
   `GET /auth/device/start?challenge=…&name=<Gerätename>`
   Der Server leitet bei Bedarf über die Pocket-ID-Anmeldung und dann nach
   `witterung://auth?code=<einmaliger Code>` (5 min gültig).
3. App: `POST /auth/device/token` mit `{"code":"…","verifier":"…"}` →
   `200 {"token":"wt_…","device_id":7}`. Token im Schlüsselbund ablegen.
4. Alle API-Aufrufe: `Authorization: Bearer wt_…`. 401 → Token verworfen, neu anmelden.

`GET /api/v1/devices` listet Geräte, `DELETE /api/v1/devices/{id}` widerruft eins.

## Orte

| | | |
|---|---|---|
| `GET /api/v1/places` | | `[Place]`, gespeicherte Orte in Reihenfolge |
| `POST /api/v1/places` | `{"name","lat","lon"}` | `201 Place` |
| `PATCH /api/v1/places/{id}` | `{"name"?, "notify"?, "position"?}` | `Place` |
| `DELETE /api/v1/places/{id}` | | `204` |

`Place = {"id", "name", "lat", "lon", "kind": "saved"|"current", "notify": bool}`.
`notify` = Push-Benachrichtigungen (Warnungen, Regenbeginn) für diesen Ort.

## Vorhersage

`GET /api/v1/places/{id}/forecast` – gespeicherter Ort.
`GET /api/v1/forecast?lat=…&lon=…` – aktueller Standort. Der Server rundet auf 0,02° und
fragt den Punkt 24 h lang mit ab. Gibt es noch keine Daten, holt er Open-Meteo und Bright Sky
sofort (dauert wenige Sekunden).

```jsonc
{
  "location": {"id": 1, "name": "Uelzen", "lat": 52.9656, "lon": 10.5594, "kind": "saved"},
  "generated_at": "2026-11-09T12:00:03Z",
  "sources": [                       // je Quelle, auch ausgefallene
    {"source": "open_meteo:icon_d2", "provider": "open_meteo", "ok": true,
     "fetched_at": "…", "stale": false, "error": null}
  ],
  "now": {
    "observed": {                    // DWD-Station (SYNOP), null wenn keine
      "station": "Uelzen", "distance_m": 3383, "at": "…",
      "temp_c": 7.5, "humidity_pct": 82, "wind_kmh": 14.4, "gust_kmh": 16.9,
      "wind_dir_deg": 160, "pressure_hpa": 1020.7, "precip_mm_1h": 0.0,
      "cloud_pct": 13, "visibility_m": 12124, "condition": "partly_cloudy"
    },
    "forecast": HourPoint            // Konsens der laufenden Stunde, null wenn keine
  },
  "nowcast": {                       // Radar (DWD RV, 5-min-Schritte, ~2 h), null wenn keins
    "source": "bright_sky:radar", "at": "…",
    "points": [{"at": "…", "precip_mm_h": 0.0}]
  },
  "hourly": [                        // 48 h ab der laufenden Stunde
    {"at": "…", "n_sources": 6,
     "consensus": HourPoint,
     "spread": {"temp_c": {"min": 4.1, "max": 5.9}, "precip_mm": {"min": 0, "max": 0.4},
                "wind_kmh": {"min": 9, "max": 17}, "precip_agreement_pct": 33},
     "by_source": {"open_meteo:icon_d2": HourPoint, "…": HourPoint}}
  ],
  "daily": [                         // 10 Tage ab heute
    {"date": "2026-11-09", "n_sources": 5,
     "consensus": DayPoint,
     "spread": {"temp_min_c": {"min","max"}, "temp_max_c": {"min","max"},
                "precip_mm": {"min","max"}, "precip_agreement_pct": 80},
     "by_source": {"…": DayPoint}}
  ],
  "alerts": [                        // DWD-Warnungen für den Ort, nach Schwere sortiert
    {"id": "…", "severity": "minor"|"moderate"|"severe"|"extreme",
     "event": "STURMBÖEN", "headline": "…", "description": "…", "instruction": "…"|null,
     "onset": "…", "expires": "…"|null, "source": "dwd"}
  ],
  "attribution": [{"source": "open_meteo", "text": "…", "url": "…"}]
}
```

`HourPoint`/`DayPoint` wie in schema.md (`at` bzw. `date` steckt auch im Konsens).
Konsens: Median je Größe über die Quellen dieser Zeile, `condition` = häufigste
(bei Gleichstand die heftigere), `is_day` = Mehrheit. `precip_agreement_pct` = Anteil der
Quellen mit ≥ 0,1 mm (Stunde) bzw. ≥ 1 mm (Tag). `n_sources` zählt nur Quellen mit Wert in
dieser Zeile. Die App zeigt die Attribution sichtbar (Apple Weather mit Logo und Link,
sobald WeatherKit aktiv ist).

## Radar-Karte

`GET /api/v1/radar` → `{"wms": "https://maps.dwd.de/geoserver/dwd/wms", "layer":
"dwd:Radar_rv_product_1x1km_ger", "frames": ["2026-11-09T10:00:00Z", …]}` – Zeitschritte
(5 min) von −2 h bis +2 h (Vorhersage), für WMS-`TIME`. Kacheln holt der Client direkt beim
DWD (EPSG:3857, `FORMAT=image/png`, `TRANSPARENT=true`). Quelle: Deutscher Wetterdienst.

## Status

`GET /health` (öffentlich): `{"status":"ok","version","sources":[{"provider","configured",
"ok","last_success_at","error"}]}`; `status` ist `degraded`, wenn eine konfigurierte Quelle
seit über 3 h nichts geliefert hat.

`GET /api/v1/status` (angemeldet): je Provider Zustand und Kontingent (`used`, `limit`,
`period`).

## Benachrichtigungen (ntfy)

`GET/PUT /api/v1/settings/notifications` `{"ntfy_url": "https://ntfy.rubeen.dev",
"topic": "…", "token": "…"|null, "enabled": bool}` (Token wird nie zurückgegeben, nur
`"token_set": true`). `POST /api/v1/settings/notifications/test` schickt eine Testnachricht.
Ausgelöst wird bei neuer DWD-Warnung (ab `moderate`) und bei Regenbeginn in < 30 min laut
Radar, je Ort mit `notify: true`.
