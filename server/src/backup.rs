//! Nightly SQLite backup: `VACUUM INTO data/backups/witterung-YYYY-MM-DD.db`
//! once per (UTC) day, the last 7 kept.

use jiff::Timestamp;

use crate::app::App;
use crate::error::AppResult;

const KEEP: usize = 7;

pub async fn maybe_run(app: &App, now: Timestamp) -> AppResult<()> {
    let dir = app.config().data_dir.join("backups");
    let file = dir.join(format!("witterung-{}.db", now.strftime("%Y-%m-%d")));
    if file.exists() {
        return Ok(());
    }
    app.blocking(move |c| {
        std::fs::create_dir_all(&dir)?;
        c.execute("VACUUM INTO ?1", [file.to_string_lossy()])?;
        let mut old: Vec<_> = std::fs::read_dir(&dir)?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("witterung-") && n.ends_with(".db"))
            })
            .collect();
        old.sort();
        for p in old.iter().take(old.len().saturating_sub(KEEP)) {
            std::fs::remove_file(p)?;
        }
        tracing::info!(file = %file.display(), "backup written");
        Ok(())
    })
    .await
}
