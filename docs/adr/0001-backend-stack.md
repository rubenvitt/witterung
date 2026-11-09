# ADR 0001: Backend in Rust (axum, SQLite)

- Status: angenommen (09.11.2026)
- Datum: 2026-11-09

## Kontext

Witterung braucht einen Aggregator, der vier Wetterquellen pollt, Kontingente durchsetzt,
Antworten normalisiert und eine eigene API für iOS-App, Widget und später das Web liefert.
Er läuft allein auf dem Homelab (ARM64, Docker Compose, Traefik, Pocket ID) und soll
nebenher mit wenig Aufwand pflegbar bleiben. Es gibt genau einen Nutzer.

Im eigenen Portfolio laufen bereits Rust-Dienste mit genau diesem Zuschnitt:

- `zunder`: axum + rusqlite/SQLite, Pocket-ID-Login für das Web, Geräte-Token per OAuth
  Authorization Code mit PKCE für native Apps, CI baut amd64 + arm64 nach GHCR.
- `drk/lagemonitor`: axum, sqlx, Poller, Bright-Sky-Adapter (Wetter, Radar).

## Optionen

Bewertet von 1 (schlecht) bis 3 (gut), Gewicht in Klammern.

| Kriterium | Rust/axum | TypeScript/Node | Swift/Vapor | Go |
|---|---|---|---|---|
| Wiederverwendung aus eigenen Projekten (3) | 3 | 1 | 1 | 1 |
| Wartungsaufwand nebenher (3) | 2 | 2 | 1 | 3 |
| Ressourcen auf ARM64, ein Binary (2) | 3 | 1 | 2 | 3 |
| Typsicherheit beim Normalisieren (2) | 3 | 2 | 3 | 2 |
| Modelle mit der iOS-App teilen (1) | 1 | 1 | 3 | 1 |
| **Summe** | **29** | **17** | **20** | **24** |

Swift/Vapor hätte den Charme gemeinsamer `Codable`-Typen mit der App, bringt aber einen
weiteren Server-Stack, den ich sonst nirgends betreibe. Go wäre ähnlich schlank wie Rust,
fängt aber bei null an.

## Entscheidung

Rust mit axum, tokio, reqwest (rustls) und rusqlite (SQLite, gebündelt). rusqlite statt sqlx, weil der übernommene Auth-Code aus `zunder` darauf aufsetzt. Ein Crate, ein Binary,
ein Container. Die Anmeldung (Pocket ID fürs Web, Geräte-Token für die App) wird aus
`zunder` übernommen, das CI-Muster für arm64-Images ebenso.

SQLite hält: Orte, Geräte-Token, Quoten-Zähler, den letzten Rohstand jeder Quelle
(Cache, überlebt Neustarts) und später das Prognose-Archiv für den Rückblick.

Der Vertrag zwischen Backend und App ist JSON. Er wird in `docs/schema.md` beschrieben
und über Fixture-Tests auf beiden Seiten abgesichert, nicht über geteilten Code.

## Konsequenzen

- Gut: bekannter Stack, kopierbare Auth, kleines Image, wenig RAM, kein Laufzeit-Zoo.
- Gut: SQLite braucht keinen zweiten Container; Backup ist eine Datei.
- Schlecht: Schema-Änderungen müssen in Rust und Swift nachgezogen werden.
- Schlecht: längere Build-Zeiten, besonders beim arm64-Cross-Build in der CI.
- Offen: Muss das Prognose-Archiv („Wie gut lag welche Quelle?“) später wachsen,
  bleibt SQLite trotzdem ausreichend (ein Nutzer, wenige Orte, stündliche Werte).
