//! Installing the HTTP server as a per-user launchd agent, and the bearer token it checks.

use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use anyhow::{Context, bail};
use serde::Serialize;

use crate::store::home_dir;

pub const LABEL: &str = "com.tenequm.Blackbox.mcp";
pub const DEFAULT_PORT: u16 = 47817;

/// Every file the agent touches, rooted at one home directory so tests can use a temp dir.
#[derive(Clone)]
pub struct Paths {
    pub plist: PathBuf,
    pub token: PathBuf,
    pub log: PathBuf,
}

impl Paths {
    pub fn under(home: &Path) -> Self {
        Self {
            plist: home
                .join("Library/LaunchAgents")
                .join(format!("{LABEL}.plist")),
            token: home.join("Library/Application Support/Blackbox/mcp-token"),
            log: home.join("Library/Logs/Blackbox/mcp.log"),
        }
    }

    pub fn real() -> Self {
        Self::under(&home_dir())
    }
}

/// The only side effect on launchd. A trait so the install/uninstall sequences are testable
/// without touching the real user session.
pub trait Launchctl {
    /// Returns whether the command exited 0, and its combined output.
    fn run(&self, args: &[&str]) -> (bool, String);
}

pub struct RealLaunchctl;

impl Launchctl for RealLaunchctl {
    fn run(&self, args: &[&str]) -> (bool, String) {
        match Command::new("launchctl").args(args).output() {
            Ok(o) => (
                o.status.success(),
                format!(
                    "{}{}",
                    String::from_utf8_lossy(&o.stdout),
                    String::from_utf8_lossy(&o.stderr)
                )
                .trim()
                .to_string(),
            ),
            Err(e) => (false, e.to_string()),
        }
    }
}

fn xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The LaunchAgent plist. `db` is baked in only when the user pinned one; otherwise the server
/// follows the app's save-folder preference on its own.
pub fn render_plist(
    binary: &Path,
    port: u16,
    db: Option<&Path>,
    token: &Path,
    log: &Path,
) -> String {
    let mut args = vec![binary.to_string_lossy().into_owned()];
    if let Some(db) = db {
        args.extend(["--db".into(), db.to_string_lossy().into_owned()]);
    }
    // Explicit, not derived from $HOME: the agent's environment is launchd's, and the token the
    // server checks must be the file `install` wrote and `print-config` points clients at.
    args.extend([
        "serve".into(),
        "--port".into(),
        port.to_string(),
        "--token-file".into(),
        token.to_string_lossy().into_owned(),
    ]);
    let args: String = args
        .iter()
        .map(|a| format!("    <string>{}</string>\n", xml(a)))
        .collect();
    let log = xml(&log.to_string_lossy());
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{LABEL}</string>
  <key>ProgramArguments</key>
  <array>
{args}  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>{log}</string>
  <key>StandardErrorPath</key>
  <string>{log}</string>
</dict>
</plist>
"#
    )
}

/// Reads the `--port` value back out of an installed plist.
pub fn port_from_plist(plist: &str) -> Option<u16> {
    let after = plist.split("<string>--port</string>").nth(1)?;
    let start = after.find("<string>")? + "<string>".len();
    let rest = &after[start..];
    rest[..rest.find("</string>")?].trim().parse().ok()
}

/// Reads the token, creating it (32 random bytes, hex, mode 0600) if it does not exist yet.
pub fn ensure_token(path: &Path) -> anyhow::Result<String> {
    if let Ok(existing) = fs::read_to_string(path) {
        let existing = existing.trim().to_string();
        if existing.len() >= 32 {
            // Repair a token that was copied around with loose permissions.
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
            return Ok(existing);
        }
    }
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    let mut bytes = [0u8; 32];
    fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    // `mode` applies at creation, so there is no window where the secret is world-readable.
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(token.as_bytes())?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(token)
}

fn uid() -> anyhow::Result<String> {
    let out = Command::new("id").arg("-u").output().context("run id -u")?;
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// A binary on a mounted DMG or in Gatekeeper's randomized translocation path disappears on
/// eject/relaunch, and the agent would then fail on every login with nothing visible to the user.
pub fn reject_ephemeral_path(binary: &Path) -> anyhow::Result<()> {
    let p = binary.to_string_lossy();
    if p.starts_with("/Volumes/") || p.contains("/AppTranslocation/") {
        bail!(
            "{p} is a temporary location (a mounted disk image or a quarantined download). Move Blackbox to /Applications, open it once from there, then install the agent again"
        );
    }
    Ok(())
}

/// Writes the token and plist, then (re)loads the agent so a rerun picks up a changed port or
/// binary path. Safe to run repeatedly.
pub fn install(
    paths: &Paths,
    launchctl: &dyn Launchctl,
    uid: &str,
    binary: &Path,
    port: u16,
    db: Option<&Path>,
) -> anyhow::Result<()> {
    if !binary.exists() {
        bail!("binary {} does not exist", binary.display());
    }
    reject_ephemeral_path(binary)?;
    ensure_token(&paths.token)?;
    for file in [&paths.plist, &paths.log] {
        if let Some(dir) = file.parent() {
            fs::create_dir_all(dir)?;
        }
    }
    fs::write(
        &paths.plist,
        render_plist(binary, port, db, &paths.token, &paths.log),
    )?;
    let domain = format!("gui/{uid}");
    let service = format!("{domain}/{LABEL}");
    // Not an error when it was never loaded.
    let _ = launchctl.run(&["bootout", &service]);
    let plist = paths.plist.to_string_lossy().into_owned();
    let (ok, out) = launchctl.run(&["bootstrap", &domain, &plist]);
    if !ok {
        bail!("launchctl bootstrap failed: {out}");
    }
    let _ = launchctl.run(&["kickstart", "-k", &service]);
    Ok(())
}

pub fn uninstall(
    paths: &Paths,
    launchctl: &dyn Launchctl,
    uid: &str,
    keep_token: bool,
) -> anyhow::Result<()> {
    let _ = launchctl.run(&["bootout", &format!("gui/{uid}/{LABEL}")]);
    for file in std::iter::once(&paths.plist).chain((!keep_token).then_some(&paths.token)) {
        match fs::remove_file(file) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e).with_context(|| format!("remove {}", file.display())),
        }
    }
    Ok(())
}

#[derive(Serialize)]
pub struct Status {
    pub installed: bool,
    pub loaded: bool,
    pub healthy: bool,
    pub port: Option<u16>,
    pub url: Option<String>,
    pub binary: Option<String>,
    pub binary_exists: bool,
    pub token_file: String,
    pub log_file: String,
}

pub fn status(paths: &Paths, launchctl: &dyn Launchctl, uid: &str) -> Status {
    let plist = fs::read_to_string(&paths.plist).ok();
    let port = plist.as_deref().and_then(port_from_plist);
    let binary = plist.as_deref().and_then(|p| {
        let after = p
            .split("<key>ProgramArguments</key>")
            .nth(1)?
            .split("<string>")
            .nth(1)?;
        Some(after.split("</string>").next()?.to_string())
    });
    let loaded = launchctl.run(&["print", &format!("gui/{uid}/{LABEL}")]).0;
    Status {
        installed: plist.is_some(),
        loaded,
        healthy: port.is_some_and(healthz),
        port,
        url: port.map(|p| format!("http://127.0.0.1:{p}/mcp")),
        binary_exists: binary.as_deref().is_some_and(|b| Path::new(b).exists()),
        binary,
        token_file: paths.token.to_string_lossy().into_owned(),
        log_file: paths.log.to_string_lossy().into_owned(),
    }
}

/// `GET /healthz` over a raw socket - one dependency fewer than an HTTP client for one request.
pub fn healthz(port: u16) -> bool {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, Duration::from_millis(500)) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(800)));
    let request =
        format!("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    let mut body = String::new();
    stream.write_all(request.as_bytes()).is_ok()
        && stream.read_to_string(&mut body).is_ok()
        && body.starts_with("HTTP/1.1 200")
}

pub fn real_uid() -> anyhow::Result<String> {
    uid()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[derive(Default)]
    struct Fake {
        calls: RefCell<Vec<String>>,
        fail_bootstrap: bool,
    }
    impl Launchctl for Fake {
        fn run(&self, args: &[&str]) -> (bool, String) {
            self.calls.borrow_mut().push(args.join(" "));
            (
                !(self.fail_bootstrap && args[0] == "bootstrap"),
                String::new(),
            )
        }
    }

    #[test]
    fn plist_escapes_paths_and_round_trips_the_port() {
        let plist = render_plist(
            Path::new("/Apps/A&B/blackbox-mcp"),
            4242,
            Some(Path::new("/x/<y>.sqlite")),
            Path::new("/t/mcp-token"),
            Path::new("/l.log"),
        );
        assert!(
            plist.contains("/Apps/A&amp;B/blackbox-mcp") && plist.contains("/x/&lt;y&gt;.sqlite")
        );
        assert!(plist.contains("<key>KeepAlive</key>"));
        assert!(plist.contains("<string>--token-file</string>\n    <string>/t/mcp-token</string>"));
        assert_eq!(port_from_plist(&plist), Some(4242));
        assert_eq!(port_from_plist("<plist/>"), None);
    }

    #[test]
    fn token_is_created_once_private_and_reused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested/mcp-token");
        let first = ensure_token(&path).unwrap();
        assert_eq!(first.len(), 64);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(ensure_token(&path).unwrap(), first);
        // A loosened file is tightened, not regenerated.
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(ensure_token(&path).unwrap(), first);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn install_unloads_before_loading_and_uninstall_cleans_up() {
        let home = tempfile::tempdir().unwrap();
        let paths = Paths::under(home.path());
        let binary = home.path().join("blackbox-mcp");
        fs::write(&binary, "").unwrap();
        let fake = Fake::default();

        install(&paths, &fake, "501", &binary, 5555, None).unwrap();
        let calls = fake.calls.borrow().clone();
        assert_eq!(calls[0], format!("bootout gui/501/{LABEL}"));
        assert!(calls[1].starts_with("bootstrap gui/501 ") && calls[1].ends_with(".plist"));
        assert_eq!(calls[2], format!("kickstart -k gui/501/{LABEL}"));
        assert!(
            paths.token.exists()
                && port_from_plist(&fs::read_to_string(&paths.plist).unwrap()) == Some(5555)
        );

        uninstall(&paths, &fake, "501", true).unwrap();
        assert!(
            !paths.plist.exists() && paths.token.exists(),
            "--keep-token keeps the secret"
        );
        uninstall(&paths, &fake, "501", false).unwrap();
        assert!(!paths.token.exists());
    }

    #[test]
    fn status_json_keys_are_the_contract_with_the_app() {
        let home = tempfile::tempdir().unwrap();
        let status = status(&Paths::under(home.path()), &Fake::default(), "501");
        let value = serde_json::to_value(&status).unwrap();
        let mut keys: Vec<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        // Mirrored by `MCPServerController.Status` (Sources/MCPServerController.swift).
        assert_eq!(
            keys,
            [
                "binary",
                "binary_exists",
                "healthy",
                "installed",
                "loaded",
                "log_file",
                "port",
                "token_file",
                "url"
            ]
        );
        assert!(!status.installed && status.port.is_none());
    }

    #[test]
    fn a_binary_on_a_disk_image_or_translocated_path_is_refused() {
        assert!(
            reject_ephemeral_path(Path::new(
                "/Volumes/Blackbox/Blackbox.app/Contents/MacOS/blackbox-mcp"
            ))
            .is_err()
        );
        assert!(
            reject_ephemeral_path(Path::new(
                "/private/var/folders/x/AppTranslocation/ABC/d/Blackbox.app/Contents/MacOS/b"
            ))
            .is_err()
        );
        assert!(
            reject_ephemeral_path(Path::new(
                "/Applications/Blackbox.app/Contents/MacOS/blackbox-mcp"
            ))
            .is_ok()
        );
    }

    #[test]
    fn install_reports_a_failed_bootstrap_and_a_missing_binary() {
        let home = tempfile::tempdir().unwrap();
        let paths = Paths::under(home.path());
        assert!(
            install(
                &paths,
                &Fake::default(),
                "501",
                &home.path().join("nope"),
                1,
                None
            )
            .is_err()
        );
        let binary = home.path().join("b");
        fs::write(&binary, "").unwrap();
        let err = install(
            &paths,
            &Fake {
                fail_bootstrap: true,
                ..Fake::default()
            },
            "501",
            &binary,
            1,
            None,
        )
        .unwrap_err();
        assert!(err.to_string().contains("bootstrap failed"));
    }
}
