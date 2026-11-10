//! `witterung` runs the server, `witterung healthcheck` checks a running one
//! (exit code 0/1, used by the Docker HEALTHCHECK; the image has no curl).

use std::process::ExitCode;

use tracing_subscriber::EnvFilter;
use witterung::Config;

const USAGE: &str = "\
Aufruf:
  witterung               Server starten (Konfiguration über WITTERUNG_*-Variablen)
  witterung healthcheck   /health des lokalen Servers prüfen (Exit-Code 0 = gesund)
  witterung place-add NAME LAT LON [notify]
                          gespeicherten Ort anlegen (z. B. per docker exec),
                          mit „notify“ gleich mit Push-Benachrichtigungen
  witterung notify-set URL TOPIC
                          ntfy einrichten und einschalten; Token (optional) auf stdin
  witterung device-add NAME
                          Gerät ohne Browser-Anmeldung anlegen (z. B. die Mac-Leiste);
                          gibt das Bearer-Token einmalig auf stdout aus
  witterung --version     Version ausgeben";

#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        [] => serve().await,
        ["healthcheck"] => healthcheck().await,
        ["place-add", name, lat, lon, rest @ ..] if rest.is_empty() || rest == ["notify"] => {
            admin(|c| {
                let (lat, lon): (f64, f64) = (lat.parse()?, lon.parse()?);
                anyhow::ensure!(
                    (-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon),
                    "Koordinaten außerhalb des gültigen Bereichs"
                );
                let p = witterung::db::insert_place(c, name, lat, lon, witterung::app::now_ms())?;
                if !rest.is_empty() {
                    let update = witterung::db::PlaceUpdate {
                        notify: Some(true),
                        ..Default::default()
                    };
                    witterung::db::update_place(c, p.id, &update)?;
                }
                println!("Ort {} angelegt: {}", p.id, p.name);
                Ok(())
            })
        }
        ["notify-set", url, topic] => admin(|c| {
            let mut token = String::new();
            std::io::Read::read_to_string(&mut std::io::stdin(), &mut token)?;
            let settings = witterung::push::Settings {
                ntfy_url: Some(url.trim_end_matches('/').to_owned()),
                topic: Some((*topic).to_owned()),
                token: Some(token.trim().to_owned()).filter(|t| !t.is_empty()),
                enabled: true,
            };
            witterung::db::set_setting(c, "notifications", &serde_json::to_string(&settings)?)?;
            println!(
                "ntfy eingerichtet (Token: {})",
                if settings.token.is_some() {
                    "ja"
                } else {
                    "nein"
                }
            );
            Ok(())
        }),
        ["device-add", name] => {
            let name = name.trim();
            admin(|c| {
                let secret = Config::from_env()?.session_secret;
                anyhow::ensure!(
                    witterung::auth::device::valid_name(name),
                    "Name: 1 bis 60 Zeichen"
                );
                let (token, id) = witterung::auth::device::issue_token(
                    c,
                    &secret,
                    name,
                    None,
                    witterung::app::now_ms(),
                )?;
                eprintln!("Gerät {id} angelegt: {name} (widerrufbar unter Geräte)");
                println!("{token}");
                Ok(())
            })
        }
        ["--version" | "-V"] => {
            println!("witterung {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        ["--help" | "-h"] => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

/// Runs `f` on the database of the configured data directory.
fn admin(f: impl FnOnce(&rusqlite::Connection) -> anyhow::Result<()>) -> ExitCode {
    let result = Config::from_env()
        .map_err(anyhow::Error::from)
        .and_then(|c| witterung::db::open(&c.db_path()))
        .and_then(|conn| f(&conn));
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("Fehler: {e}");
            ExitCode::FAILURE
        }
    }
}

async fn serve() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();
    let config = match Config::from_env() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    match witterung::run(config).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            tracing::error!(error = ?e, "server stopped with an error");
            ExitCode::FAILURE
        }
    }
}

async fn healthcheck() -> ExitCode {
    let bind = match Config::from_env() {
        Ok(c) => c.bind,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    match witterung::healthcheck::check(bind).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("ungesund: {e}");
            ExitCode::FAILURE
        }
    }
}
