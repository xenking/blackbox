//! Read-only access to Blackbox's `transcripts.sqlite` (written by `TranscriptIndex.swift`).
//!
//! The app owns the schema; this side only ever opens the file read-only and refuses a
//! `user_version` it was not written for, so a future app schema change fails loudly here
//! instead of returning wrong rows.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::{Local, NaiveDate, NaiveDateTime, TimeZone};
use rusqlite::{Connection, OpenFlags, ToSql, functions::FunctionFlags, types::ValueRef};
use serde_json::{Map, Value, json};

/// `PRAGMA user_version` the app stamps on the index (`TranscriptIndex.schema`).
pub const SCHEMA_VERSION: i64 = 1;
pub const APP_BUNDLE_ID: &str = "com.tenequm.Blackbox";
pub const DB_FILE: &str = "transcripts.sqlite";

#[derive(Debug)]
pub enum StoreError {
    /// The index file is not there yet (fresh install, or nothing transcribed).
    NoIndex(PathBuf),
    /// The caller asked for something that does not exist or is malformed.
    Invalid(String),
    Db(String),
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoIndex(p) => write!(
                f,
                "no transcript index at {} - transcribe a recording in Blackbox first (it is created with the first transcript)",
                p.display()
            ),
            Self::Invalid(m) | Self::Db(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<rusqlite::Error> for StoreError {
    fn from(e: rusqlite::Error) -> Self {
        Self::Db(e.to_string())
    }
}

pub fn bad(msg: impl Into<String>) -> StoreError {
    StoreError::Invalid(msg.into())
}

/// Where the index lives. An explicit path wins; otherwise it follows the app's own
/// "save folder" preference, re-read (cached a few seconds) so moving the library in
/// Settings is picked up without restarting the agent.
#[derive(Clone)]
pub struct Store {
    explicit: Option<PathBuf>,
}

static RESOLVED: Mutex<Option<(Instant, PathBuf)>> = Mutex::new(None);
const RESOLVE_TTL: Duration = Duration::from_secs(5);

impl Store {
    pub fn new(explicit: Option<PathBuf>) -> Self {
        Self { explicit }
    }

    pub fn db_path(&self) -> PathBuf {
        if let Some(p) = &self.explicit {
            return p.clone();
        }
        let mut cache = RESOLVED.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((at, path)) = cache.as_ref().filter(|(at, _)| at.elapsed() < RESOLVE_TTL) {
            let _ = at;
            return path.clone();
        }
        let path = save_directory().join(DB_FILE);
        *cache = Some((Instant::now(), path.clone()));
        path
    }

    pub fn open(&self) -> Result<Connection, StoreError> {
        let path = self.db_path();
        if !path.exists() {
            return Err(StoreError::NoIndex(path));
        }
        let conn = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.execute_batch("PRAGMA query_only = ON;")?;
        // SQLite's lower() only folds ASCII, so a Russian title would never match a
        // lowercased filter. `ulower` is full Unicode lowercasing, the same one used on the input.
        conn.create_scalar_function(
            "ulower",
            1,
            FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC,
            |ctx| Ok(ctx.get::<Option<String>>(0)?.map(|s| s.to_lowercase())),
        )?;
        let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version != SCHEMA_VERSION {
            return Err(StoreError::Db(format!(
                "transcript index schema is v{version}, this server understands v{SCHEMA_VERSION} - update Blackbox and blackbox-mcp together"
            )));
        }
        Ok(conn)
    }
}

/// The app's save folder: its `saveDirectoryPath` preference, else the built-in default.
fn save_directory() -> PathBuf {
    let fallback = home_dir().join("Library/Application Support/Blackbox/Recordings");
    // `defaults` is the sanctioned reader: it goes through cfprefsd, which the app
    // writes to, so a plist file read could lag behind a just-changed setting.
    Command::new("defaults")
        .args(["read", APP_BUNDLE_ID, "saveDirectoryPath"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or(fallback)
}

pub fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

/// Runs a query and returns each row as a JSON object keyed by column name.
pub fn query(
    conn: &Connection,
    sql: &str,
    params: &[(&str, &dyn ToSql)],
) -> Result<Vec<Value>, StoreError> {
    let mut stmt = conn.prepare(sql)?;
    let names: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
    let rows = stmt.query_map(params, |row| {
        let mut obj = Map::new();
        for (i, name) in names.iter().enumerate() {
            obj.insert(
                name.clone(),
                match row.get_ref(i)? {
                    ValueRef::Null | ValueRef::Blob(_) => Value::Null,
                    ValueRef::Integer(n) => json!(n),
                    ValueRef::Real(f) => json!(f),
                    ValueRef::Text(t) => json!(String::from_utf8_lossy(t)),
                },
            );
        }
        Ok(Value::Object(obj))
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

pub fn one(
    conn: &Connection,
    sql: &str,
    params: &[(&str, &dyn ToSql)],
) -> Result<Option<Value>, StoreError> {
    Ok(query(conn, sql, params)?.into_iter().next())
}

/// Builds a safe FTS5 expression. Every word is quoted, so user text can never inject FTS
/// syntax. `all`/`any` prefix-match each word; `phrase` keeps the words adjacent and in order.
pub fn fts(text: &str, mode: Option<&str>) -> Result<String, StoreError> {
    let words: Vec<String> = text
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.chars().count() >= 2)
        .map(str::to_string)
        .collect();
    if words.is_empty() {
        return Err(bad("query has no searchable words"));
    }
    let prefix = |w: &str| {
        let n = w.chars().count();
        // shortcut: crude stemming (drop the last 2 letters of long words) so Russian
        // inflections match; upgrade to a real stemmer if recall/precision matters.
        let stem: String = if n >= 6 {
            w.chars().take(n - 2).collect()
        } else {
            w.to_string()
        };
        format!("\"{stem}\"{}", if n >= 3 { "*" } else { "" })
    };
    match mode.unwrap_or("all") {
        "all" => Ok(words
            .iter()
            .map(|w| prefix(w))
            .collect::<Vec<_>>()
            .join(" AND ")),
        "any" => Ok(words
            .iter()
            .map(|w| prefix(w))
            .collect::<Vec<_>>()
            .join(" OR ")),
        "phrase" => Ok(format!("\"{}\"", words.join(" "))),
        other => Err(bad(format!(
            "mode must be 'all', 'any' or 'phrase', got '{other}'"
        ))),
    }
}

/// `YYYY-MM-DD`, `YYYY-MM-DD HH:MM[:SS]` (local time) or RFC 3339 -> Unix seconds.
/// A bare date as an upper bound means *through the end of that day*.
pub fn parse_time(text: &str, end_of_day: bool) -> Result<f64, StoreError> {
    let text = text.trim();
    let local = |naive: NaiveDateTime| {
        Local
            .from_local_datetime(&naive)
            .earliest()
            .map(|d| d.timestamp() as f64)
            .ok_or_else(|| bad(format!("'{text}' does not exist in the local time zone")))
    };
    if let Ok(d) = chrono::DateTime::parse_from_rfc3339(text) {
        return Ok(d.timestamp() as f64);
    }
    for fmt in [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M",
    ] {
        if let Ok(n) = NaiveDateTime::parse_from_str(text, fmt) {
            return local(n);
        }
    }
    if let Ok(d) = NaiveDate::parse_from_str(text, "%Y-%m-%d") {
        let day = if end_of_day {
            d.succ_opt().unwrap_or(d)
        } else {
            d
        };
        return local(day.and_hms_opt(0, 0, 0).expect("midnight is valid"));
    }
    Err(bad(format!(
        "'{text}' is not a date: use YYYY-MM-DD, 'YYYY-MM-DD HH:MM' or RFC 3339"
    )))
}

pub fn iso(epoch: f64) -> String {
    Local
        .timestamp_opt(epoch as i64, 0)
        .single()
        .map(|d| d.to_rfc3339_opts(chrono::SecondsFormat::Secs, false))
        .unwrap_or_default()
}

/// `mm:ss`, or `h:mm:ss` from one hour on.
pub fn clock(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s % 3600 / 60, s % 60)
    } else {
        format!("{:02}:{:02}", s / 60, s % 60)
    }
}

/// Mirrors the app's `speakerName(for:)`: a name the user set wins, `-1` is the local
/// microphone ("Я"), everything else is `Speaker N` (Soniox ids are 0-based).
pub fn speaker_label(speaker: i64, names: &Value) -> String {
    if let Some(name) = names
        .get(speaker.to_string())
        .and_then(Value::as_str)
        .filter(|n| !n.is_empty())
    {
        return name.to_string();
    }
    if speaker == -1 {
        "Я".into()
    } else {
        format!("Speaker {}", speaker.saturating_add(1))
    }
}

pub fn clamp_limit(requested: Option<i64>, default: i64, max: i64) -> i64 {
    requested.unwrap_or(default).clamp(1, max)
}

pub fn path_str(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fts_quotes_every_word_and_cannot_inject_syntax() {
        // `OR`/`NEAR` and the parentheses are plain words/separators here, never operators.
        assert_eq!(
            fts("релиз OR NEAR(a b)", None).unwrap(),
            "\"релиз\"* AND \"OR\" AND \"NEAR\"*"
        );
        // Punctuation and operators are word separators, never syntax.
        let q = fts("a\" OR \"b*", Some("any")).unwrap();
        assert!(!q.contains("*\"*"), "{q}");
        assert_eq!(
            fts("x", None).unwrap_err().to_string(),
            "query has no searchable words"
        );
    }

    #[test]
    fn fts_modes() {
        assert_eq!(
            fts("обсудим релиз", Some("all")).unwrap(),
            "\"обсуд\"* AND \"релиз\"*"
        );
        assert_eq!(
            fts("hello world", Some("any")).unwrap(),
            "\"hello\"* OR \"world\"*"
        );
        assert_eq!(
            fts("hello  world!", Some("phrase")).unwrap(),
            "\"hello world\""
        );
        assert!(fts("hello", Some("fuzzy")).is_err());
    }

    #[test]
    fn dates_are_local_and_upper_bound_covers_the_day() {
        let start = parse_time("2026-10-20", false).unwrap();
        let end = parse_time("2026-10-20", true).unwrap();
        assert!(
            end - start >= 23.0 * 3600.0 && end - start <= 25.0 * 3600.0,
            "DST-safe day length"
        );
        assert_eq!(parse_time("2026-10-20 00:00", false).unwrap(), start);
        assert_eq!(
            parse_time("2026-10-20T10:00:00+00:00", false).unwrap(),
            1_792_490_400.0
        );
        assert!(parse_time("yesterday", false).is_err());
    }

    #[test]
    fn speakers_follow_the_apps_labels() {
        let names = json!({"1": "Anna", "2": ""});
        assert_eq!(speaker_label(-1, &names), "Я");
        assert_eq!(speaker_label(1, &names), "Anna");
        assert_eq!(speaker_label(2, &names), "Speaker 3");
        assert_eq!(
            speaker_label(i64::MAX, &names),
            format!("Speaker {}", i64::MAX)
        );
    }

    #[test]
    fn clock_formats() {
        assert_eq!(clock(65.4), "01:05");
        assert_eq!(clock(3725.0), "1:02:05");
        assert_eq!(clock(-3.0), "00:00");
    }
}
