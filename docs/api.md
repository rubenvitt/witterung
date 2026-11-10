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

**Ohne Browser (z. B. Mac-Menüleiste):** Das Token erzeugt die Web-App unter Verwaltung →
Geräte, also `POST /api/v1/devices` mit `{"name"}` (1–60 Zeichen) → `201 {"token":"wt_…",
"device_id":7}`. Das geht nur mit Browser-Sitzung; mit einem Geräte-Token kommt `403`. Ohne
Oberfläche geht dasselbe auf dem Server: `docker exec witterung witterung device-add <Name>` gibt
`wt_…` auf stdout aus. Das Token wird in beiden Fällen nur einmal gezeigt. Danach wie oben
`Authorization: Bearer wt_…`; das Gerät steht in der Geräteliste und ist dort widerrufbar.

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
"dwd:Radar_rv_product_1x1km_ger", "frames": ["2026-11-09T10:00:00Z", …], "now_index": 24,
"attribution": "Radar: Deutscher Wetterdienst"}` – `now_index` ist das letzte Analysebild,
danach Vorhersage. Zeitschritte
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

## MCP (Agenten)

`POST /mcp`: MCP-Server für Claude und andere Agenten (Streamable HTTP, JSON-RPC 2.0,
Protokollversion `2025-06-18`, auch `2025-03-26`). Zustandslos, ohne Server-Stream (`GET` → 405).
Anfragen bekommen `200` mit JSON, reine Benachrichtigungen `202` ohne Inhalt; Batches gehen.

Anmeldung nur per `Authorization: Bearer …`, Cookies und Dev-Anmeldung zählen hier nicht:

- **Geräte-Token** `wt_…` (Web-App unter Verwaltung → Geräte oder `witterung device-add`), für
  Clients mit festem Header wie Claude Code.
- **OAuth-Access-Token** `woa_…` aus dem eingebauten Autorisierungsserver, für Clients ohne festen
  Header wie Connectoren in claude.ai.

Ohne gültiges Token kommt `401` mit `WWW-Authenticate: Bearer resource_metadata="<public>/.well-known/oauth-protected-resource"`.
Ein mitgeschickter `Origin` muss `WITTERUNG_PUBLIC_URL` sein (sonst `403`).

| Werkzeug | Zweck |
|---|---|
| `list_places` | gespeicherte Orte |
| `get_forecast` | `place` (ID oder Name) oder `lat`/`lon`; `hours` 0–48 (24), `days` 0–10 (7), `by_source` |
| `get_alerts` | DWD-Warnungen eines Orts oder aller gespeicherten Orte |
| `get_source_status` | Zustand und Kontingent der Quellen (wie `/api/v1/status`) |
| `create_place`, `update_place`, `delete_place` | Orte verwalten (wie `/api/v1/places`) |

`get_forecast` liefert dieselbe Aggregation wie `/api/v1/…/forecast`, aber für ein Sprachmodell
geformt: Zeiten in Europe/Berlin mit Offset, Felder ohne Wert fehlen, Werte je Quelle nur mit
`by_source`, der Nowcast als Satz (`summary`, Punkte nur bei Niederschlag). Freie Koordinaten
werden wie `/api/v1/forecast` auf ≈ 2 km gerundet und 24 h mitgepollt. Fehler eines Werkzeugs sind
Ergebnisse mit `isError: true` und deutscher Meldung, Protokollfehler JSON-RPC-Fehler.

### OAuth (claude.ai)

Witterung ist für `/mcp` Ressourcen- und Autorisierungsserver zugleich (OAuth 2.1, MCP Authorization):

| | |
|---|---|
| `GET /.well-known/oauth-protected-resource[/mcp]` | RFC 9728, `resource` = `<public>/mcp` |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 |
| `POST /oauth/register` | dynamische Registrierung (RFC 7591), nur öffentliche Clients; Redirect-URIs https, http auf localhost oder App-Schema; 10 je Stunde und Adresse, 200 insgesamt |
| `GET /oauth/authorize` | Code-Flow mit PKCE S256; ohne Sitzung über die Pocket-ID-Anmeldung, dann Freigabeseite |
| `POST /oauth/token` | `authorization_code` und `refresh_token` |
| `POST /oauth/revoke` | RFC 7009 |

Codes gelten 5 min und einmal (eine Wiederholung widerruft, was mit ihnen ausgestellt wurde).
Access-Tokens gelten 1 h, Refresh-Tokens 30 Tage und rotieren; ein zweites Mal eingelöster
Refresh-Token trennt die Verbindung. Gespeichert wird nur ein HMAC der Tokens.

`GET /api/v1/connections` listet die verbundenen Apps (`[{"id","name","redirect_uris",
"created_at","last_used_at"}]`, nur mit gültiger Freigabe), `DELETE /api/v1/connections/{id}`
trennt eine samt allen Tokens.
