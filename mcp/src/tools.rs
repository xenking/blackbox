//! The MCP surface: four read-only tools over the transcript index.

use rmcp::{
    ErrorData, ServerHandler,
    handler::server::wrapper::Parameters,
    model::{CallToolResult, ContentBlock},
    tool, tool_handler, tool_router,
};
use rusqlite::{Connection, ToSql};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::store::{
    Store, StoreError, bad, clamp_limit, clock, fts, iso, meeting, one, parse_time, path_str,
    query, speaker_label,
};

type ToolResult = Result<CallToolResult, ErrorData>;

/// schemars renders `Option<T>` as `"type": ["T", "null"]` plus `format`; strict MCP clients
/// (Codex, OpenAI tools) cope better with plain types, and optional fields are already absent
/// from `required`.
fn plain_optionals(schema: &mut schemars::Schema) {
    let Some(props) = schema.get_mut("properties").and_then(Value::as_object_mut) else {
        return;
    };
    for prop in props.values_mut().filter_map(Value::as_object_mut) {
        if let Some(Value::Array(types)) = prop.get("type").cloned()
            && let Some(t) = types.into_iter().find(|t| t != "null")
        {
            prop.insert("type".into(), t);
        }
        prop.remove("format");
    }
}

#[derive(Deserialize, JsonSchema)]
#[schemars(transform = plain_optionals)]
struct SearchTranscripts {
    /// Words to find (Russian or English; each is prefix-matched, long words are stemmed a little).
    query: String,
    /// "all" (default, every word), "any" (at least one) or "phrase" (the words adjacent and in order).
    mode: Option<String>,
    /// Only recordings made on/after this local date or time: YYYY-MM-DD, "YYYY-MM-DD HH:MM" or RFC 3339.
    since: Option<String>,
    /// Only recordings made through this date/time (a bare date includes that whole day).
    until: Option<String>,
    /// Case-insensitive substring of the app OR the window/browser-tab title the call ran in, e.g. "zoom", "meet" or "weekly sync".
    app: Option<String>,
    /// Restrict to one recording id (the `recording` value from list_recordings).
    recording: Option<String>,
    /// "me" (the local microphone), "others" (everyone else), or a numeric speaker id.
    speaker: Option<String>,
    /// Transcript language code, e.g. "ru".
    language: Option<String>,
    /// Max hits (default 20, max 100).
    limit: Option<i64>,
}

#[derive(Deserialize, JsonSchema)]
#[schemars(transform = plain_optionals)]
struct ListRecordings {
    /// Only recordings made on/after this local date or time.
    since: Option<String>,
    /// Only recordings made through this date/time (a bare date includes that whole day).
    until: Option<String>,
    /// Case-insensitive substring of the app OR the window/browser-tab title, e.g. "chrome" or "standup".
    app: Option<String>,
    /// Case-insensitive substring of the recording title.
    title_contains: Option<String>,
    /// Transcript language code, e.g. "ru".
    language: Option<String>,
    /// Max rows (default 30, max 200).
    limit: Option<i64>,
    /// Skip this many rows (paging).
    offset: Option<i64>,
}

#[derive(Deserialize, JsonSchema)]
#[schemars(transform = plain_optionals)]
struct GetTranscript {
    /// Recording id, as returned by list_recordings / search_transcripts.
    recording: String,
    /// First segment index to return (default 0). For context around a search hit use hit.idx - 3.
    from_idx: Option<i64>,
    /// Max segments (default 300, max 2000).
    limit: Option<i64>,
    /// Only segments starting at/after this many seconds into the recording.
    start_sec: Option<f64>,
    /// Only segments starting before this many seconds into the recording.
    end_sec: Option<f64>,
    /// Stop after about this many characters of transcript (default 20000, max 100000); `next_idx` continues.
    max_chars: Option<i64>,
}

#[derive(Clone)]
pub struct Server {
    store: Store,
}

impl Server {
    pub fn new(store: Store) -> Self {
        Self { store }
    }

    /// Runs `f` against a fresh read-only connection and turns store errors into tool output:
    /// a bad argument is a protocol error, anything else (no index yet, schema mismatch) is
    /// reported as a tool error the model can read and relay.
    fn with(&self, f: impl FnOnce(&Connection) -> Result<Value, StoreError>) -> ToolResult {
        let outcome = self.store.open().and_then(|conn| {
            // One read transaction for the whole call. In WAL mode each autocommit statement
            // gets its own snapshot, so with the app committing an upsert between two SELECTs a
            // response could pair old metadata with new segments, or a total with other rows.
            // BEGIN is deferred: the snapshot is taken by the first SELECT and held until `conn`
            // drops and rolls back, including the freshness query below.
            conn.execute_batch("BEGIN")?;
            let body = f(&conn)?;
            let freshness = one(
                &conn,
                "SELECT count(*) AS recordings, max(transcribed_at) AS newest FROM transcripts",
                &[],
            )?
            .unwrap_or(Value::Null);
            let newest = freshness["newest"].as_f64().map(iso);
            Ok(json!({
                "index": { "recordings": freshness["recordings"], "newest_transcript": newest },
                "result": body,
            }))
        });
        match outcome {
            Ok(payload) => Ok(CallToolResult::structured(payload)),
            Err(StoreError::Invalid(msg)) => Err(ErrorData::invalid_params(msg, None)),
            Err(other) => Ok(CallToolResult::error(vec![ContentBlock::text(
                other.to_string(),
            )])),
        }
    }
}

/// The shared WHERE for `recorded_at`/app/language filters, over a `transcripts t` alias.
const RECORDING_FILTER: &str = "(:since IS NULL OR t.recorded_at >= :since) AND (:until IS NULL OR t.recorded_at < :until)
     AND (:app IS NULL OR instr(ulower(coalesce(t.app_name, '')), :app) > 0) AND (:language IS NULL OR t.language = :language)";

fn lower(v: &Option<String>) -> Option<String> {
    v.as_ref()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
}

fn time_bounds(
    since: &Option<String>,
    until: &Option<String>,
) -> Result<(Option<f64>, Option<f64>), StoreError> {
    let parse = |v: &Option<String>, end: bool| {
        v.as_deref()
            .filter(|s| !s.trim().is_empty())
            .map(|s| parse_time(s, end))
            .transpose()
    };
    Ok((parse(since, false)?, parse(until, true)?))
}

/// ("any" | "me" | "others" | "id", speaker id) for the SQL speaker predicate.
fn speaker_filter(spec: &Option<String>) -> Result<(&'static str, i64), StoreError> {
    match spec.as_deref().map(|s| s.trim().to_lowercase()).as_deref() {
        None | Some("") => Ok(("any", 0)),
        Some("me" | "я" | "mic") => Ok(("me", -1)),
        Some("others" | "other") => Ok(("others", 0)),
        Some(n) => n
            .parse::<i64>()
            .map(|id| ("id", id))
            .map_err(|_| bad("speaker must be 'me', 'others' or a numeric speaker id")),
    }
}

#[tool_router]
impl Server {
    #[tool(
        description = "What the transcript index holds: recording count, date range, languages/models, and where it lives. Call first when unsure whether a transcript exists; only recordings whose transcription has finished in Blackbox are indexed."
    )]
    fn index_status(&self) -> ToolResult {
        let path = self.store.db_path();
        self.with(|c| {
            let range = one(
                c,
                "SELECT count(*) AS recordings, min(recorded_at) AS oldest, max(recorded_at) AS newest, max(transcribed_at) AS last_transcribed FROM transcripts",
                &[],
            )?
            .unwrap_or(Value::Null);
            let segments = one(c, "SELECT count(*) AS n FROM segments", &[])?.map(|r| r["n"].clone());
            let languages = query(c, "SELECT language, count(*) AS recordings FROM transcripts GROUP BY 1 ORDER BY 2 DESC", &[])?;
            let apps = query(c, "SELECT coalesce(app, app_name) AS app, count(*) AS recordings FROM transcripts GROUP BY 1 ORDER BY 2 DESC LIMIT 20", &[])?;
            let models = query(c, "SELECT coalesce(provider,'') || ' ' || coalesce(model,'') AS model, count(*) AS recordings FROM transcripts GROUP BY 1 ORDER BY 2 DESC", &[])?;
            Ok(json!({
                "database": path_str(&path),
                "recordings": range["recordings"],
                "segments": segments,
                "oldest_recording": range["oldest"].as_f64().map(iso),
                "newest_recording": range["newest"].as_f64().map(iso),
                "last_transcribed": range["last_transcribed"].as_f64().map(iso),
                "languages": languages,
                "apps": apps,
                "models": models,
                "speaker_labels": "Я = the local microphone (the user); others are named by the user or 'Speaker N'",
            }))
        })
    }

    #[tool(
        description = "Full-text search across all transcripts (ranked). Returns segment hits with recording id, title, `meeting` (app, window/browser-tab title, bundle id, start time), position (idx and mm:ss), speaker and a highlighted snippet. Filters: date range, app, one recording, speaker (me/others/id), language. Follow up with get_transcript (from_idx = idx - 3) for context."
    )]
    fn search_transcripts(&self, Parameters(p): Parameters<SearchTranscripts>) -> ToolResult {
        let q = fts(&p.query, p.mode.as_deref())?;
        let (since, until) = time_bounds(&p.since, &p.until)?;
        let (app, language) = (
            lower(&p.app),
            p.language
                .as_ref()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
        );
        let (spk, spk_id) = speaker_filter(&p.speaker)?;
        let n = clamp_limit(p.limit, 20, 100);
        let from = "FROM segments_fts JOIN segments s ON s.id = segments_fts.rowid JOIN transcripts t ON t.recording = s.recording";
        let filter = format!(
            "segments_fts MATCH :q AND {RECORDING_FILTER} AND (:recording IS NULL OR s.recording = :recording)
             AND (:spk = 'any' OR (:spk = 'me' AND s.speaker = -1) OR (:spk = 'others' AND s.speaker <> -1) OR (:spk = 'id' AND s.speaker = :spk_id))"
        );
        self.with(|c| {
            let args: [(&str, &dyn ToSql); 8] = [
                (":q", &q), (":since", &since), (":until", &until), (":app", &app), (":language", &language),
                (":recording", &p.recording), (":spk", &spk), (":spk_id", &spk_id),
            ];
            let total = one(c, &format!("SELECT count(*) AS n {from} WHERE {filter}"), &args)?.map(|r| r["n"].clone());
            let mut all: Vec<(&str, &dyn ToSql)> = args.to_vec();
            all.push((":n", &n));
            let rows = query(
                c,
                &format!(
                    "SELECT s.recording, t.title, t.app_name, t.app, t.window_title, t.bundle_id, t.recorded_at, t.language, t.speakers_json, s.idx, s.speaker, s.start, s.text,
                            snippet(segments_fts, 0, '[', ']', '…', 24) AS snippet
                     {from} WHERE {filter} ORDER BY bm25(segments_fts), t.recorded_at DESC, s.idx LIMIT :n"
                ),
                &all,
            )?;
            let hits: Vec<Value> = rows
                .into_iter()
                .map(|r| {
                    let names = r["speakers_json"].as_str().and_then(|j| serde_json::from_str(j).ok()).unwrap_or(Value::Null);
                    json!({
                        "recording": r["recording"], "title": r["title"],
                        "meeting": meeting(&r, None), "recorded_at": r["recorded_at"].as_f64().map(iso),
                        "language": r["language"],
                        "idx": r["idx"], "time": clock(r["start"].as_f64().unwrap_or(0.0)),
                        "speaker": speaker_label(r["speaker"].as_i64().unwrap_or(0), &names),
                        "text": r["text"], "snippet": r["snippet"],
                    })
                })
                .collect();
            Ok(json!({ "total_matches": total, "returned": hits.len(), "hits": hits }))
        })
    }

    #[tool(
        description = "List transcribed recordings, newest first, each with title, `meeting` (app, window/browser-tab title, bundle id, start time, approximate end, duration), language and segment count. Filters: date range, app or tab text, title text, language. Use the `recording` id with get_transcript or search_transcripts."
    )]
    fn list_recordings(&self, Parameters(p): Parameters<ListRecordings>) -> ToolResult {
        let (since, until) = time_bounds(&p.since, &p.until)?;
        let (app, language) = (
            lower(&p.app),
            p.language
                .as_ref()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
        );
        let title = lower(&p.title_contains);
        let (n, offset) = (clamp_limit(p.limit, 30, 200), p.offset.unwrap_or(0).max(0));
        let filter = format!(
            "{RECORDING_FILTER} AND (:title IS NULL OR instr(ulower(t.title), :title) > 0)"
        );
        self.with(|c| {
            let args: [(&str, &dyn ToSql); 5] = [(":since", &since), (":until", &until), (":app", &app), (":language", &language), (":title", &title)];
            let total = one(c, &format!("SELECT count(*) AS n FROM transcripts t WHERE {filter}"), &args)?.map(|r| r["n"].clone());
            let mut all: Vec<(&str, &dyn ToSql)> = args.to_vec();
            all.extend([(":n", &n as &dyn ToSql), (":offset", &offset)]);
            let rows = query(
                c,
                &format!(
                    "SELECT t.recording, t.title, t.app_name, t.app, t.window_title, t.bundle_id, t.recorded_at, t.transcribed_at, t.language, t.model,
                            (SELECT count(*) FROM segments s WHERE s.recording = t.recording) AS segments,
                            (SELECT max(coalesce(s.end, s.start)) FROM segments s WHERE s.recording = t.recording) AS duration_sec
                     FROM transcripts t WHERE {filter} ORDER BY t.recorded_at DESC, t.recording DESC LIMIT :n OFFSET :offset"
                ),
                &all,
            )?;
            let rows: Vec<Value> = rows
                .into_iter()
                .map(|r| {
                    json!({
                        "recording": r["recording"], "title": r["title"],
                        "meeting": meeting(&r, r["duration_sec"].as_f64()),
                        "transcribed_at": r["transcribed_at"].as_f64().map(iso),
                        "language": r["language"], "model": r["model"], "segments": r["segments"],
                    })
                })
                .collect();
            Ok(json!({ "total": total, "returned": rows.len(), "offset": offset, "recordings": rows }))
        })
    }

    #[tool(
        description = "Read a transcript as numbered, timestamped lines ('#12 [03:41] Я: text'). Pages by segment index (from_idx/limit/max_chars; continue from next_idx) or by time (start_sec/end_sec). The speaker 'Я' is the local microphone, i.e. the user."
    )]
    fn get_transcript(&self, Parameters(p): Parameters<GetTranscript>) -> ToolResult {
        let from = p.from_idx.unwrap_or(0).max(0);
        let n = clamp_limit(p.limit, 300, 2000);
        let budget = clamp_limit(p.max_chars, 20_000, 100_000) as usize;
        self.with(|c| {
            let Some(t) = one(
                c,
                "SELECT recording, title, app_name, app, window_title, bundle_id, recorded_at, transcribed_at, language, provider, model, speakers_json
                 FROM transcripts WHERE recording = :r",
                &[(":r", &p.recording)],
            )?
            else {
                return Err(bad(format!("recording '{}' not found - use list_recordings or search_transcripts to get ids", p.recording)));
            };
            let names: Value = t["speakers_json"].as_str().and_then(|j| serde_json::from_str(j).ok()).unwrap_or(Value::Null);
            let total = one(c, "SELECT count(*) AS n FROM segments WHERE recording = :r", &[(":r", &p.recording)])?.map(|r| r["n"].clone());
            let duration = one(c, "SELECT max(coalesce(end, start)) AS d FROM segments WHERE recording = :r", &[(":r", &p.recording)])?
                .and_then(|r| r["d"].as_f64());
            let fetch = n + 1;
            let rows = query(
                c,
                "SELECT idx, speaker, start, text FROM segments
                 WHERE recording = :r AND idx >= :from AND (:s IS NULL OR start >= :s) AND (:e IS NULL OR start < :e)
                 ORDER BY idx LIMIT :n",
                &[(":r", &p.recording), (":from", &from), (":s", &p.start_sec), (":e", &p.end_sec), (":n", &fetch)],
            )?;
            let mut text = String::new();
            let (mut returned, mut next_idx) = (0usize, None);
            for (i, r) in rows.iter().enumerate() {
                let line = format!(
                    "#{} [{}] {}: {}\n",
                    r["idx"], clock(r["start"].as_f64().unwrap_or(0.0)),
                    speaker_label(r["speaker"].as_i64().unwrap_or(0), &names), r["text"].as_str().unwrap_or("")
                );
                // Always return at least one line so a single oversized segment cannot stall paging.
                if i as i64 >= n || (returned > 0 && text.len() + line.len() > budget) {
                    next_idx = r["idx"].as_i64();
                    break;
                }
                text.push_str(&line);
                returned += 1;
            }
            Ok(json!({
                "recording": t["recording"], "title": t["title"],
                "meeting": meeting(&t, duration), "transcribed_at": t["transcribed_at"].as_f64().map(iso),
                "language": t["language"], "provider": t["provider"], "model": t["model"], "speakers": names,
                "total_segments": total, "from_idx": from, "returned": returned, "next_idx": next_idx,
                "transcript": text,
            }))
        })
    }
}

#[tool_handler(
    name = "blackbox",
    version = "0.1.0",
    instructions = "Read-only search over the user's call/meeting transcripts recorded by Blackbox. Only recordings whose transcription finished are indexed (call index_status to see the range). Speaker 'Я' is the user's own microphone; other speakers are named by the user or 'Speaker N'. Search with search_transcripts, then read context with get_transcript (from_idx = hit idx - 3). Cite recording id, title, date and the mm:ss position; never state facts that are not in a tool result, and say so when nothing matched."
)]
impl ServerHandler for Server {}

impl From<StoreError> for ErrorData {
    fn from(e: StoreError) -> Self {
        match e {
            StoreError::Invalid(m) => ErrorData::invalid_params(m, None),
            other => ErrorData::internal_error(other.to_string(), None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::SCHEMA_VERSION;
    use rusqlite::Connection;

    /// The app commits an upsert between two statements of one tool call. Without a read
    /// transaction the second SELECT sees the new row and the response contradicts itself.
    #[test]
    fn one_call_sees_one_committed_index_generation() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("transcripts.sqlite");
        let writer = Connection::open(&path).unwrap();
        writer
            .execute_batch(&format!(
                "PRAGMA journal_mode = WAL;
                 CREATE TABLE transcripts(recording TEXT PRIMARY KEY, transcribed_at REAL);
                 INSERT INTO transcripts VALUES ('a', 1.0);
                 PRAGMA user_version = {SCHEMA_VERSION};"
            ))
            .unwrap();
        let server = Server::new(Store::new(Some(path)));

        let result = server
            .with(|conn| {
                let count = |c: &Connection| {
                    c.query_row("SELECT count(*) FROM transcripts", [], |r| {
                        r.get::<_, i64>(0)
                    })
                    .unwrap()
                };
                let before = count(conn);
                writer
                    .execute("INSERT INTO transcripts VALUES ('b', 2.0)", [])
                    .unwrap();
                Ok(json!({ "before": before, "after": count(conn) }))
            })
            .unwrap();

        let payload = &result.structured_content.unwrap();
        assert_eq!(
            payload["result"],
            json!({ "before": 1, "after": 1 }),
            "one snapshot per call"
        );
        // The freshness figure in the same response comes from that snapshot too.
        assert_eq!(payload["index"]["recordings"], json!(1));
        // The next call sees the commit.
        let next = server
            .with(|_| Ok(Value::Null))
            .unwrap()
            .structured_content
            .unwrap();
        assert_eq!(next["index"]["recordings"], json!(2));
    }
}
