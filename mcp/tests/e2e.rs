//! Drives the real binary over the real MCP protocol (stdio and HTTP) against a database
//! built with the app's own schema, so a drift between `TranscriptIndex.swift` and these
//! queries fails here instead of in front of an agent.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::Duration;

use rusqlite::Connection;
use serde_json::{Value, json};

const BIN: &str = env!("CARGO_BIN_EXE_blackbox-mcp");

/// The `schema` literal from the Swift source, verbatim.
fn app_schema() -> String {
    let swift = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../Sources/TranscriptIndex.swift"
    ))
    .unwrap();
    let start = swift
        .find("private static let schema = \"\"\"")
        .expect("schema literal")
        + "private static let schema = \"\"\"".len();
    let end = start + swift[start..].find("\"\"\"").expect("schema end");
    swift[start..end].to_string()
}

// 2026-10-20 10:00 and 2026-10-21 10:00 UTC.
const DAY1: f64 = 1_792_490_400.0;
const DAY2: f64 = 1_792_576_800.0;

fn fixture(dir: &Path) -> PathBuf {
    let path = dir.join("transcripts.sqlite");
    let db = Connection::open(&path).unwrap();
    db.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        .unwrap();
    db.execute_batch(&app_schema()).unwrap();
    db.execute_batch("PRAGMA user_version = 1").unwrap();
    for (name, title, app, at, lang, speakers) in [
        (
            "2610-20-zoom",
            "Планёрка",
            "Zoom",
            DAY1,
            "ru",
            Some(r#"{"1":"Anna"}"#),
        ),
        (
            "2610-21-meet",
            "Design sync",
            "Google Meet",
            DAY2,
            "en",
            None,
        ),
    ] {
        db.execute(
            "INSERT INTO transcripts(recording, title, app_name, recorded_at, transcribed_at, language, provider, model, speakers_json, source_mtime)
             VALUES (?, ?, ?, ?, ?, ?, 'soniox', 'stt-async-v4', ?, 0)",
            rusqlite::params![name, title, app, at, at + 600.0, lang, speakers],
        )
        .unwrap();
    }
    let segs: [(&str, i64, i64, f64, &str); 5] = [
        (
            "2610-20-zoom",
            0,
            -1,
            0.0,
            "Привет, давайте обсудим релиз в пятницу",
        ),
        (
            "2610-20-zoom",
            1,
            1,
            6.5,
            "Релиз откладываем, тесты не готовы",
        ),
        (
            "2610-20-zoom",
            2,
            2,
            12.0,
            "Согласен, перенесём на следующую неделю",
        ),
        ("2610-20-zoom", 3, -1, 3725.0, "Хорошо, до связи"),
        (
            "2610-21-meet",
            0,
            0,
            1.0,
            "Let's review the release checklist",
        ),
    ];
    for (rec, idx, speaker, start, text) in segs {
        db.execute(
            "INSERT INTO segments(recording, idx, speaker, start, end, text) VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params![rec, idx, speaker, start, start + 2.0, text],
        )
        .unwrap();
    }
    path
}

struct StdioClient {
    child: Child,
    stdin: ChildStdin,
    out: BufReader<ChildStdout>,
    next: u64,
}

impl StdioClient {
    fn start(db: &Path) -> Self {
        let mut child = Command::new(BIN)
            .args(["--db", &db.to_string_lossy(), "stdio"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let (stdin, out) = (
            child.stdin.take().unwrap(),
            BufReader::new(child.stdout.take().unwrap()),
        );
        let mut s = Self {
            child,
            stdin,
            out,
            next: 1,
        };
        s.call("initialize", json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "0"}}));
        writeln!(
            s.stdin,
            "{}",
            json!({"jsonrpc": "2.0", "method": "notifications/initialized"})
        )
        .unwrap();
        s
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        writeln!(
            self.stdin,
            "{}",
            json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
        )
        .unwrap();
        loop {
            let mut line = String::new();
            assert!(
                self.out.read_line(&mut line).unwrap() > 0,
                "server closed stdout"
            );
            let msg: Value = serde_json::from_str(&line).unwrap();
            if msg["id"] == json!(id) {
                return msg;
            }
        }
    }

    /// Calls a tool and returns its structured `result` payload.
    fn tool(&mut self, name: &str, args: Value) -> Value {
        let reply = self.call("tools/call", json!({"name": name, "arguments": args}));
        assert!(reply["error"].is_null(), "{reply}");
        assert_eq!(reply["result"]["isError"], json!(false), "{reply}");
        reply["result"]["structuredContent"]["result"].clone()
    }
}

impl Drop for StdioClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

#[test]
fn exposes_the_four_read_only_tools_with_plain_schemas() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = StdioClient::start(&fixture(dir.path()));
    let tools = s.call("tools/list", json!({}))["result"]["tools"].clone();
    let mut names: Vec<&str> = tools
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    names.sort_unstable();
    assert_eq!(
        names,
        [
            "get_transcript",
            "index_status",
            "list_recordings",
            "search_transcripts"
        ]
    );
    // Strict clients reject `["string","null"]` unions; optionals must be plain types.
    let search = tools
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "search_transcripts")
        .unwrap();
    assert_eq!(
        search["inputSchema"]["properties"]["since"]["type"],
        json!("string")
    );
}

#[test]
fn search_finds_inflections_labels_speakers_and_highlights() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = StdioClient::start(&fixture(dir.path()));

    // "релизе" must find "релиз" (stemming) in both languages' rows of the Russian recording.
    let r = s.tool("search_transcripts", json!({"query": "релизе"}));
    assert_eq!(r["total_matches"], json!(2));
    let hits = r["hits"].as_array().unwrap();
    assert!(hits.iter().all(|h| h["recording"] == "2610-20-zoom"
        && h["title"] == "Планёрка"
        && h["app"] == "Zoom"));
    assert!(
        hits.iter()
            .any(|h| h["idx"] == 0 && h["speaker"] == "Я" && h["time"] == "00:00")
    );
    let named = hits.iter().find(|h| h["idx"] == 1).unwrap();
    assert_eq!(named["speaker"], json!("Anna"));
    assert!(
        named["snippet"].as_str().unwrap().contains('['),
        "match is highlighted"
    );

    // Filters narrow it.
    let me = s.tool(
        "search_transcripts",
        json!({"query": "релиз", "speaker": "me"}),
    );
    assert_eq!(me["hits"].as_array().unwrap().len(), 1);
    let others = s.tool(
        "search_transcripts",
        json!({"query": "релиз", "speaker": "others"}),
    );
    assert_eq!(others["hits"][0]["idx"], json!(1));
    let en = s.tool(
        "search_transcripts",
        json!({"query": "release", "app": "meet"}),
    );
    assert_eq!(en["hits"][0]["recording"], json!("2610-21-meet"));
    let none = s.tool(
        "search_transcripts",
        json!({"query": "релиз", "since": "2030-01-01"}),
    );
    assert_eq!(none["total_matches"], json!(0));
    let day1 = s.tool(
        "search_transcripts",
        json!({"query": "release", "until": "2026-10-20"}),
    );
    assert_eq!(
        day1["total_matches"],
        json!(0),
        "the English recording is on the 21st"
    );
    let phrase = s.tool(
        "search_transcripts",
        json!({"query": "релиз откладываем", "mode": "phrase"}),
    );
    assert_eq!(phrase["total_matches"], json!(1));
}

#[test]
fn list_and_read_recordings_with_paging() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = StdioClient::start(&fixture(dir.path()));

    let list = s.tool("list_recordings", json!({}));
    assert_eq!(list["total"], json!(2));
    assert_eq!(
        list["recordings"][0]["recording"],
        json!("2610-21-meet"),
        "newest first"
    );
    let zoom = &list["recordings"][1];
    assert_eq!(zoom["segments"], json!(4));
    assert_eq!(zoom["duration"], json!("1:02:07"));
    assert_eq!(
        s.tool("list_recordings", json!({"title_contains": "ПЛАНЁР"}))["total"],
        json!(1)
    );

    let page = s.tool(
        "get_transcript",
        json!({"recording": "2610-20-zoom", "limit": 2}),
    );
    assert_eq!(page["returned"], json!(2));
    assert_eq!(page["next_idx"], json!(2));
    assert_eq!(
        page["transcript"].as_str().unwrap().lines().next().unwrap(),
        "#0 [00:00] Я: Привет, давайте обсудим релиз в пятницу"
    );
    let rest = s.tool(
        "get_transcript",
        json!({"recording": "2610-20-zoom", "from_idx": 2}),
    );
    assert_eq!(rest["next_idx"], Value::Null);
    assert!(
        rest["transcript"]
            .as_str()
            .unwrap()
            .contains("#3 [1:02:05] Я: Хорошо")
    );
    // The character budget pages too, and always returns at least one line.
    let tiny = s.tool(
        "get_transcript",
        json!({"recording": "2610-20-zoom", "max_chars": 1}),
    );
    assert_eq!(
        (tiny["returned"].clone(), tiny["next_idx"].clone()),
        (json!(1), json!(1))
    );
    let window = s.tool(
        "get_transcript",
        json!({"recording": "2610-20-zoom", "start_sec": 5, "end_sec": 20}),
    );
    assert_eq!(window["returned"], json!(2));

    let status = s.tool("index_status", json!({}));
    assert_eq!(
        (status["recordings"].clone(), status["segments"].clone()),
        (json!(2), json!(5))
    );
}

#[test]
fn bad_arguments_are_protocol_errors_and_a_missing_index_is_a_readable_tool_error() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = StdioClient::start(&fixture(dir.path()));
    let missing = s.call(
        "tools/call",
        json!({"name": "get_transcript", "arguments": {"recording": "nope"}}),
    );
    assert!(
        missing["error"]["message"]
            .as_str()
            .unwrap()
            .contains("not found"),
        "{missing}"
    );
    let date = s.call(
        "tools/call",
        json!({"name": "list_recordings", "arguments": {"since": "yesterday"}}),
    );
    assert!(
        date["error"]["message"]
            .as_str()
            .unwrap()
            .contains("not a date"),
        "{date}"
    );
    let words = s.call(
        "tools/call",
        json!({"name": "search_transcripts", "arguments": {"query": "?!"}}),
    );
    assert!(words["error"].is_object());
    drop(s);

    let mut empty = StdioClient::start(&dir.path().join("absent.sqlite"));
    let reply = empty.call(
        "tools/call",
        json!({"name": "index_status", "arguments": {}}),
    );
    assert_eq!(reply["result"]["isError"], json!(true));
    assert!(
        reply["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("transcribe a recording"),
        "{reply}"
    );
}

#[test]
fn an_index_still_being_created_and_an_unreadable_one_say_so() {
    let dir = tempfile::tempdir().unwrap();
    let db = fixture(dir.path());
    Connection::open(&db)
        .unwrap()
        .execute_batch("PRAGMA user_version = 0")
        .unwrap();
    let mut s = StdioClient::start(&db);
    let reply = s.call(
        "tools/call",
        json!({"name": "index_status", "arguments": {}}),
    );
    assert!(
        reply["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("still being created"),
        "{reply}"
    );
    drop(s);

    // A directory the process may not enter is a permission problem, not a missing index.
    let locked = dir.path().join("locked");
    std::fs::create_dir(&locked).unwrap();
    std::fs::copy(&db, locked.join("transcripts.sqlite")).unwrap();
    std::fs::set_permissions(&locked, std::os::unix::fs::PermissionsExt::from_mode(0o000)).unwrap();
    let mut s = StdioClient::start(&locked.join("transcripts.sqlite"));
    let reply = s.call(
        "tools/call",
        json!({"name": "index_status", "arguments": {}}),
    );
    std::fs::set_permissions(&locked, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    assert!(
        reply["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Full Disk Access"),
        "{reply}"
    );
}

#[test]
fn refuses_a_schema_version_it_was_not_written_for() {
    let dir = tempfile::tempdir().unwrap();
    let db = fixture(dir.path());
    Connection::open(&db)
        .unwrap()
        .execute_batch("PRAGMA user_version = 2")
        .unwrap();
    let mut s = StdioClient::start(&db);
    let reply = s.call(
        "tools/call",
        json!({"name": "index_status", "arguments": {}}),
    );
    assert_eq!(reply["result"]["isError"], json!(true));
    assert!(
        reply["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("schema is v2")
    );
}

// ---- HTTP ----

struct Http {
    child: Child,
    /// Kept open: a closed stderr pipe makes the server's own logging fail mid-request.
    _stderr: BufReader<std::process::ChildStderr>,
    port: u16,
    token: String,
}

impl Http {
    fn start(db: &Path, home: &Path) -> Self {
        let mut child = Command::new(BIN)
            .args([
                "--db",
                &db.to_string_lossy(),
                "serve",
                "--port",
                "0",
                "--token-file",
                &home.join("token").to_string_lossy(),
            ])
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stderr = BufReader::new(child.stderr.take().unwrap());
        let mut line = String::new();
        stderr.read_line(&mut line).unwrap();
        let port = line
            .split("127.0.0.1:")
            .nth(1)
            .and_then(|r| r.split('/').next())
            .and_then(|p| p.parse().ok())
            .unwrap_or_else(|| panic!("no port in {line:?}"));
        let token = std::fs::read_to_string(home.join("token")).unwrap();
        Self {
            child,
            _stderr: stderr,
            port,
            token,
        }
    }

    /// One raw HTTP/1.1 request. Rejection tests send an empty body: a server that answers
    /// 401 before reading a body and then closes resets the socket, which can eat the reply.
    /// One raw HTTP/1.1 request; returns (status, lowercase header block, body).
    fn request(
        &self,
        method: &str,
        path: &str,
        headers: &[(&str, &str)],
        body: &str,
    ) -> (u16, String, String) {
        let mut stream = TcpStream::connect(("127.0.0.1", self.port)).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let mut req = format!(
            "{method} {path} HTTP/1.1\r\nConnection: close\r\nContent-Length: {}\r\n",
            body.len()
        );
        if !headers.iter().any(|(k, _)| k.eq_ignore_ascii_case("host")) {
            req.push_str(&format!("Host: 127.0.0.1:{}\r\n", self.port));
        }
        for (k, v) in headers {
            req.push_str(&format!("{k}: {v}\r\n"));
        }
        req.push_str("\r\n");
        req.push_str(body);
        stream.write_all(req.as_bytes()).unwrap();
        let mut raw = String::new();
        let read = stream.read_to_string(&mut raw);
        if raw.is_empty() {
            panic!(
                "empty response from {method} {path} headers={headers:?} body={body:.60}: {read:?}"
            );
        }
        let (head, body) = raw.split_once("\r\n\r\n").unwrap_or((&raw, ""));
        let status = head
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        (status, head.to_lowercase(), body.to_string())
    }

    fn mcp(&self, session: Option<&str>, payload: Value) -> (u16, String, Value) {
        let auth = format!("Bearer {}", self.token.trim());
        let mut headers = vec![
            ("Authorization", auth.as_str()),
            ("Content-Type", "application/json"),
            ("Accept", "application/json, text/event-stream"),
            ("MCP-Protocol-Version", "2025-06-18"),
        ];
        if let Some(s) = session {
            headers.push(("Mcp-Session-Id", s));
        }
        let (status, head, body) = self.request("POST", "/mcp", &headers, &payload.to_string());
        let json = body
            .lines()
            .map(str::trim)
            .filter_map(|l| l.strip_prefix("data:").map(str::trim).or(Some(l)))
            .find_map(|l| serde_json::from_str::<Value>(l).ok())
            .unwrap_or(Value::Null);
        (status, head, json)
    }
}

impl Drop for Http {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

#[test]
fn http_endpoint_is_token_protected_and_serves_the_same_tools() {
    let dir = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let server = Http::start(&fixture(dir.path()), home.path());

    // Health is open; the MCP endpoint is not.
    assert_eq!(server.request("GET", "/healthz", &[], "").0, 200);
    assert_eq!(
        server
            .request("POST", "/mcp", &[("Content-Type", "application/json")], "")
            .0,
        401
    );
    let (status, head, _) =
        server.request("POST", "/mcp", &[("Authorization", "Bearer wrong")], "");
    assert_eq!(status, 401);
    assert!(head.contains("www-authenticate: bearer"));

    let (status, head, init) = server.mcp(None, json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "0"}}}));
    assert_eq!(status, 200, "{head}");
    assert_eq!(init["result"]["serverInfo"]["name"], json!("blackbox"));
    let session = head
        .lines()
        .find_map(|l| l.strip_prefix("mcp-session-id:"))
        .map(|s| s.trim().to_string());
    server.mcp(
        session.as_deref(),
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
    );

    let (status, _, reply) = server.mcp(session.as_deref(), json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "search_transcripts", "arguments": {"query": "релизе"}}}));
    assert_eq!(status, 200);
    assert_eq!(
        reply["result"]["structuredContent"]["result"]["total_matches"],
        json!(2),
        "{reply}"
    );

    // A foreign Host header (DNS rebinding) is refused even with the right token.
    let auth = format!("Bearer {}", server.token.trim());
    let (status, _, _) = server.request(
        "POST",
        "/mcp",
        &[
            ("Authorization", auth.as_str()),
            ("Host", "evil.example"),
            ("Content-Type", "application/json"),
            ("Accept", "application/json, text/event-stream"),
        ],
        "",
    );
    assert!(status == 403 || status == 400, "foreign host got {status}");
}
