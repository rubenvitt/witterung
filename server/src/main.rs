//! `witterung` runs the server, `witterung healthcheck` checks a running one
//! (exit code 0/1, used by the Docker HEALTHCHECK; the image has no curl).

use std::process::ExitCode;

use tracing_subscriber::EnvFilter;
use witterung::Config;

const USAGE: &str = "\
Aufruf:
  witterung               Server starten (Konfiguration über WITTERUNG_*-Variablen)
  witterung healthcheck   /health des lokalen Servers prüfen (Exit-Code 0 = gesund)
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
