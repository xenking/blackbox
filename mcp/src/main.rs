//! blackbox-mcp: a read-only MCP server over Blackbox's transcript index.
//!
//! `stdio` serves one client over stdin/stdout (no network, no token). `serve` is the
//! always-on HTTP endpoint the LaunchAgent runs: loopback only, bearer-token protected.

mod agent;
mod store;
mod tools;

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::Context;
use axum::{
    Router,
    extract::{Request, State},
    http::{StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
};
use clap::{Parser, Subcommand};
use rmcp::{
    ServiceExt,
    transport::{
        stdio,
        streamable_http_server::{
            StreamableHttpServerConfig, StreamableHttpService, session::local::LocalSessionManager,
        },
    },
};
use tokio_util::sync::CancellationToken;

use crate::store::Store;

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    /// Path to transcripts.sqlite. Default: the save folder Blackbox is configured with.
    #[arg(long, env = "BLACKBOX_DB", global = true)]
    db: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Serve one MCP client over stdin/stdout.
    Stdio,
    /// Serve MCP over HTTP on 127.0.0.1 (what the LaunchAgent runs).
    Serve {
        #[arg(long, env = "BLACKBOX_MCP_PORT", default_value_t = agent::DEFAULT_PORT)]
        port: u16,
        /// Where the bearer token lives (created with mode 0600 if missing).
        #[arg(long, env = "BLACKBOX_MCP_TOKEN_FILE")]
        token_file: Option<PathBuf>,
    },
    /// Install and start the per-user LaunchAgent that runs `serve`.
    InstallAgent {
        #[arg(long, default_value_t = agent::DEFAULT_PORT)]
        port: u16,
        /// Binary the agent should run (default: this one).
        #[arg(long)]
        binary: Option<PathBuf>,
    },
    /// Stop and remove the LaunchAgent (and the token, unless --keep-token).
    UninstallAgent {
        #[arg(long)]
        keep_token: bool,
    },
    /// Whether the agent is installed, loaded and answering.
    Status {
        #[arg(long)]
        json: bool,
    },
    /// Print ready-to-paste client configuration.
    PrintConfig {
        /// Inline the bearer token instead of reading it from the token file.
        #[arg(long)]
        show_token: bool,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Logs go to stderr: on `stdio` stdout carries the protocol.
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .init();
    let cli = Cli::parse();
    let store = Store::new(cli.db.clone());
    match cli.command {
        Command::Stdio => {
            let running = tools::Server::new(store)
                .serve(stdio())
                .await
                .context("start stdio transport")?;
            running.waiting().await?;
            Ok(())
        }
        Command::Serve { port, token_file } => serve(store, port, token_file).await,
        Command::InstallAgent { port, binary } => {
            let binary = match binary {
                Some(b) => b,
                None => std::env::current_exe()?.canonicalize()?,
            };
            let paths = agent::Paths::real();
            agent::install(
                &paths,
                &agent::RealLaunchctl,
                &agent::real_uid()?,
                &binary,
                port,
                cli.db.as_deref(),
            )?;
            println!("installed {} on http://127.0.0.1:{port}/mcp", agent::LABEL);
            println!("token: {}", paths.token.display());
            println!("run `blackbox-mcp print-config` for client setup");
            Ok(())
        }
        Command::UninstallAgent { keep_token } => {
            agent::uninstall(
                &agent::Paths::real(),
                &agent::RealLaunchctl,
                &agent::real_uid()?,
                keep_token,
            )?;
            println!("removed {}", agent::LABEL);
            Ok(())
        }
        Command::Status { json } => {
            let status = agent::status(
                &agent::Paths::real(),
                &agent::RealLaunchctl,
                &agent::real_uid()?,
            );
            if json {
                println!("{}", serde_json::to_string_pretty(&status)?);
            } else {
                println!(
                    "installed: {}  loaded: {}  healthy: {}",
                    status.installed, status.loaded, status.healthy
                );
                println!("url: {}", status.url.as_deref().unwrap_or("-"));
                println!(
                    "binary: {} (exists: {})",
                    status.binary.as_deref().unwrap_or("-"),
                    status.binary_exists
                );
            }
            Ok(())
        }
        Command::PrintConfig { show_token } => print_config(show_token),
    }
}

fn print_config(show_token: bool) -> anyhow::Result<()> {
    let paths = agent::Paths::real();
    let status = agent::status(&paths, &agent::RealLaunchctl, &agent::real_uid()?);
    let port = status.port.unwrap_or(agent::DEFAULT_PORT);
    let url = format!("http://127.0.0.1:{port}/mcp");
    let binary = std::env::current_exe()?.canonicalize()?;
    let token_file = paths.token.display();
    let bearer = if show_token {
        agent::ensure_token(&paths.token)?
    } else {
        "<token>".to_string()
    };
    if !status.installed {
        println!(
            "# The HTTP agent is not installed: run `blackbox-mcp install-agent` first (stdio below works without it).\n"
        );
    }
    let bearer_cmd = if show_token {
        bearer.clone()
    } else {
        format!("$(cat '{token_file}')")
    };
    println!(
        "# ===== Codex (~/.codex/config.toml - the Codex app and the CLI share it) =====
# A server has either `command` or `url`, never both: use ONE of these two blocks.
#
# A) stdio. Recommended for the Codex app: no network listener, no token, and no
#    environment to arrange (a GUI app does not inherit your shell's variables).
[mcp_servers.blackbox]
command = \"{}\"
args = [\"stdio\"]

# B) the always-on HTTP agent. Replace block A with this, and make BLACKBOX_MCP_TOKEN
#    visible to Codex: export BLACKBOX_MCP_TOKEN=$(cat '{token_file}')
# [mcp_servers.blackbox]
# url = \"{url}\"
# bearer_token_env_var = \"BLACKBOX_MCP_TOKEN\"",
        binary.display()
    );
    println!(
        "\n# ===== Claude Code (HTTP agent; token file {token_file}, mode 0600) =====\nclaude mcp add --transport http blackbox {url} --header \"Authorization: Bearer {bearer_cmd}\"\n# or stdio: claude mcp add blackbox -- {} stdio",
        binary.display()
    );
    println!(
        "\n# ===== Generic mcp.json (HTTP agent) =====\n{{ \"mcpServers\": {{ \"blackbox\": {{ \"type\": \"http\", \"url\": \"{url}\", \"headers\": {{ \"Authorization\": \"Bearer {bearer}\" }} }} }} }}"
    );
    Ok(())
}

/// Constant-time equality, so response timing does not leak how much of a guess matched.
fn token_matches(given: &str, expected: &str) -> bool {
    let (a, b) = (given.as_bytes(), expected.as_bytes());
    let mut diff = a.len() ^ b.len();
    for i in 0..a.len().max(b.len()) {
        diff |= usize::from(a.get(i).copied().unwrap_or(0) ^ b.get(i).copied().unwrap_or(0));
    }
    diff == 0
}

async fn require_token(State(token): State<Arc<str>>, req: Request, next: Next) -> Response {
    let given = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    if given.is_some_and(|g| token_matches(g, &token)) {
        next.run(req).await
    } else {
        (
            StatusCode::UNAUTHORIZED,
            [(header::WWW_AUTHENTICATE, "Bearer")],
            "missing or invalid bearer token\n",
        )
            .into_response()
    }
}

/// The HTTP app: `/healthz` open (launchd and `status` poll it), `/mcp` behind the token.
fn app(store: Store, token: Arc<str>, cancel: CancellationToken) -> Router {
    let mut config = StreamableHttpServerConfig::default();
    config.cancellation_token = cancel.child_token();
    let service: StreamableHttpService<tools::Server, LocalSessionManager> =
        StreamableHttpService::new(
            move || Ok(tools::Server::new(store.clone())),
            Arc::default(),
            config,
        );
    Router::new()
        .nest_service("/mcp", service)
        .layer(middleware::from_fn_with_state(token, require_token))
        .route("/healthz", get(|| async { "ok" }))
}

async fn serve(store: Store, port: u16, token_file: Option<PathBuf>) -> anyhow::Result<()> {
    let token_file = token_file.unwrap_or_else(|| agent::Paths::real().token);
    let token: Arc<str> = agent::ensure_token(&token_file)?.into();
    // Loopback only, on purpose: transcripts are private call content, and there is no flag to widen it.
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
        .await
        .with_context(|| format!("bind 127.0.0.1:{port}"))?;
    let addr = listener.local_addr()?;
    let cancel = CancellationToken::new();
    eprintln!(
        "blackbox-mcp listening on http://{addr}/mcp (index: {})",
        store.db_path().display()
    );
    axum::serve(listener, app(store, token, cancel.clone()))
        .with_graceful_shutdown(async move {
            shutdown_signal().await;
            cancel.cancel();
        })
        .await?;
    Ok(())
}

async fn shutdown_signal() {
    use tokio::signal::unix::{SignalKind, signal};
    let mut term = signal(SignalKind::terminate()).expect("install SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = term.recv() => {}
    }
    tracing::info!("shutting down");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_comparison() {
        assert!(token_matches("abc", "abc"));
        assert!(!token_matches("abc", "abd"));
        assert!(!token_matches("ab", "abc"));
        assert!(!token_matches("", "abc"));
        assert!(token_matches("", ""));
    }
}
