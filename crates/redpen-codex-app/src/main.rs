#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::{
    env, fs,
    net::Ipv4Addr,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use anyhow::{Context, Result, anyhow, bail};
use clap::{Parser, Subcommand};
use futures_util::{
    SinkExt, StreamExt,
    stream::{SplitSink, SplitStream},
};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::{
    io::AsyncWriteExt,
    net::{TcpListener, TcpStream},
    process::Command,
    time::{sleep, timeout},
};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async, tungstenite::protocol::Message,
};

const DEFAULT_CODEX_APP: &str = "/Applications/Codex.app";
const BINDING_NAME: &str = "__redpenCodexApp";
const INJECT_JS: &str = include_str!("../../../assets/codex-app/renderer-inject.js");
const BUNDLED_COACH_CODEX: &str =
    include_str!("../../../plugins/redpen-codex/shared/coach_codex.sh");
const BUNDLED_COACH_PROMPTS: &str =
    include_str!("../../../plugins/redpen-codex/shared/coach_prompts.sh");
const BUNDLED_RENDER_DIFF: &str =
    include_str!("../../../plugins/redpen-codex/shared/render_diff.py");

#[derive(Parser)]
#[command(name = "redpen-codex-app")]
#[command(about = "Launch Codex App with redpen feedback injected through CDP.")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Launch(LaunchArgs),
}

#[derive(Parser, Debug)]
struct LaunchArgs {
    #[arg(long, default_value = DEFAULT_CODEX_APP)]
    codex_app: PathBuf,

    #[arg(long)]
    coach_script: Option<PathBuf>,

    #[arg(long)]
    debug_port: Option<u16>,
}

#[derive(Deserialize)]
struct CoachRequest {
    prompt: String,
    #[serde(rename = "requestId")]
    request_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct BridgeRequest {
    id: String,
    route: String,
    payload: Value,
}

#[derive(Debug, Deserialize)]
struct DebugTarget {
    #[serde(rename = "type")]
    kind: String,
    title: Option<String>,
    url: Option<String>,
    #[serde(rename = "webSocketDebuggerUrl")]
    websocket_debugger_url: Option<String>,
}

type WsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;
type WsWrite = SplitSink<WsStream, Message>;
type WsRead = SplitStream<WsStream>;

struct CdpClient {
    write: WsWrite,
    read: WsRead,
    next_id: u64,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Launch(args) => launch(args).await,
    }
}

async fn launch(args: LaunchArgs) -> Result<()> {
    let codex_app = args.codex_app;
    ensure_codex_app(&codex_app)?;
    ensure_codex_not_running(&codex_app).await?;

    let coach_script = resolve_coach_script(args.coach_script)?;

    let debug_port = match args.debug_port {
        Some(port) => port,
        None => free_port().await?,
    };

    let mut codex_process = spawn_codex_app(&codex_app, debug_port)
        .await
        .context("failed to launch Codex App")?;

    let target = match wait_for_target(debug_port).await {
        Ok(target) => target,
        Err(err) => {
            let _ = codex_process.kill().await;
            return Err(err);
        }
    };
    let mut cdp = CdpClient::connect(
        target
            .websocket_debugger_url
            .as_deref()
            .context("target did not expose a websocket debugger URL")?,
    )
    .await?;
    install_redpen(&mut cdp).await?;

    println!("redpen launcher injected into Codex App on CDP port {debug_port}.");

    let mut pump = tokio::spawn(async move { cdp.pump_bindings(coach_script).await });
    tokio::select! {
        status = codex_process.wait() => {
            pump.abort();
            let status = status?;
            if !status.success() {
                bail!("Codex App exited with status {}", status);
            }
        }
        pump_result = &mut pump => {
            let _ = codex_process.kill().await;
            pump_result.context("redpen bridge task panicked")??;
        }
    }

    Ok(())
}

async fn install_redpen(client: &mut CdpClient) -> Result<()> {
    let bridge_script = build_bridge_script()?;
    let renderer_script = build_renderer_script(&bridge_script);

    client.call("Runtime.enable", json!({})).await?;
    client.call("Page.enable", json!({})).await?;
    let _ = client
        .call("Runtime.removeBinding", json!({ "name": BINDING_NAME }))
        .await;
    client
        .call("Runtime.addBinding", json!({ "name": BINDING_NAME }))
        .await?;
    client
        .call(
            "Page.addScriptToEvaluateOnNewDocument",
            json!({ "source": renderer_script }),
        )
        .await?;
    client
        .call(
            "Runtime.evaluate",
            json!({
                "expression": build_renderer_script(&bridge_script),
                "awaitPromise": false,
                "returnByValue": false,
                "allowUnsafeEvalBlockedByCSP": true,
            }),
        )
        .await?;
    Ok(())
}

async fn run_coach(coach_script: &Path, payload: CoachRequest) -> Result<Value> {
    let mut command = Command::new("bash");
    command
        .arg(coach_script)
        .env("REDPEN_OUTPUT", "structured")
        .env("REDPEN_HOST", "codex-app")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let mut child = command.spawn().with_context(|| {
        format!(
            "failed to spawn redpen coach script at {}",
            coach_script.display()
        )
    })?;

    let body = json!({
        "prompt": payload.prompt,
        "requestId": payload.request_id,
    });
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(serde_json::to_string(&body)?.as_bytes())
            .await?;
    }

    let output = timeout(Duration::from_secs(90), child.wait_with_output())
        .await
        .context("redpen coach timed out")??;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("redpen coach failed: {}", truncate_for_json(&stderr, 300));
    }

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if stdout.is_empty() {
        return Ok(json!({ "status": "skipped" }));
    }

    let value: Value = serde_json::from_str(&stdout).with_context(|| {
        format!(
            "redpen coach returned invalid JSON: {}",
            truncate_for_json(&stdout, 300)
        )
    })?;
    Ok(value)
}

fn resolve_coach_script(explicit: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(path) = explicit {
        return canonicalize_coach_script(&path);
    }
    if let Some(path) = env::var_os("REDPEN_COACH_SCRIPT") {
        return canonicalize_coach_script(Path::new(&path));
    }
    ensure_bundled_coach()
}

fn canonicalize_coach_script(path: &Path) -> Result<PathBuf> {
    path.canonicalize()
        .with_context(|| format!("cannot resolve coach script at {}", path.display()))
}

fn ensure_bundled_coach() -> Result<PathBuf> {
    let dir = bundled_runtime_dir()?;
    ensure_bundled_coach_in(&dir)
}

fn ensure_bundled_coach_in(dir: &Path) -> Result<PathBuf> {
    fs::create_dir_all(&dir)
        .with_context(|| format!("failed to create runtime directory {}", dir.display()))?;

    write_bundled_file(
        &dir.join("coach_codex.sh"),
        BUNDLED_COACH_CODEX,
        Some(0o755),
    )?;
    write_bundled_file(
        &dir.join("coach_prompts.sh"),
        BUNDLED_COACH_PROMPTS,
        Some(0o644),
    )?;
    write_bundled_file(
        &dir.join("render_diff.py"),
        BUNDLED_RENDER_DIFF,
        Some(0o644),
    )?;

    Ok(dir.join("coach_codex.sh"))
}

fn bundled_runtime_dir() -> Result<PathBuf> {
    let home = env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("redpen-codex-app")
        .join("runtime")
        .join(env!("CARGO_PKG_VERSION")))
}

fn write_bundled_file(path: &Path, content: &str, mode: Option<u32>) -> Result<()> {
    let should_write = match fs::read_to_string(path) {
        Ok(existing) => existing != content,
        Err(_) => true,
    };
    if should_write {
        fs::write(path, content)
            .with_context(|| format!("failed to write bundled file {}", path.display()))?;
    }
    #[cfg(unix)]
    if let Some(mode) = mode {
        fs::set_permissions(path, fs::Permissions::from_mode(mode))
            .with_context(|| format!("failed to chmod bundled file {}", path.display()))?;
    }
    Ok(())
}

fn ensure_codex_app(codex_app: &Path) -> Result<()> {
    let macos_bin = codex_app.join("Contents/MacOS/Codex");
    if !macos_bin.exists() {
        bail!(
            "Codex App executable not found at {}. Pass --codex-app if your install lives elsewhere.",
            macos_bin.display()
        );
    }
    Ok(())
}

async fn ensure_codex_not_running(codex_app: &Path) -> Result<()> {
    let macos_bin = codex_app.join("Contents/MacOS/Codex");
    let output = Command::new("ps")
        .args(["-axo", "command"])
        .output()
        .await
        .context("failed to inspect running processes")?;
    let commands = String::from_utf8_lossy(&output.stdout);
    let marker = macos_bin.to_string_lossy();
    if commands.lines().any(|line| line.contains(marker.as_ref())) {
        bail!(
            "Codex App is already running. Quit it first, then launch through redpen so remote debugging can be enabled."
        );
    }
    Ok(())
}

async fn spawn_codex_app(codex_app: &Path, debug_port: u16) -> Result<tokio::process::Child> {
    let mut command = Command::new("open");
    command
        .arg("-W")
        .arg("-n")
        .arg(codex_app)
        .arg("--args")
        .arg(format!("--remote-debugging-port={debug_port}"))
        .arg(format!(
            "--remote-allow-origins=http://127.0.0.1:{debug_port}"
        ));
    Ok(command.spawn()?)
}

async fn free_port() -> Result<u16> {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
    Ok(listener.local_addr()?.port())
}

async fn wait_for_target(debug_port: u16) -> Result<DebugTarget> {
    let endpoint = format!("http://127.0.0.1:{debug_port}/json");
    let client = reqwest::Client::new();
    let mut last_err = None;

    for _ in 0..80 {
        match client.get(&endpoint).send().await {
            Ok(response) => match response.json::<Vec<DebugTarget>>().await {
                Ok(targets) => {
                    if let Some(target) = choose_target(targets) {
                        return Ok(target);
                    }
                    last_err = Some(anyhow!("debug endpoint had no page targets yet"));
                }
                Err(err) => last_err = Some(err.into()),
            },
            Err(err) => last_err = Some(err.into()),
        }
        sleep(Duration::from_millis(250)).await;
    }

    Err(last_err.unwrap_or_else(|| anyhow!("timed out waiting for Codex debug target")))
}

fn choose_target(targets: Vec<DebugTarget>) -> Option<DebugTarget> {
    let mut pages = targets
        .into_iter()
        .filter(|target| target.kind == "page" && target.websocket_debugger_url.is_some())
        .collect::<Vec<_>>();

    let preferred = pages.iter().position(|target| {
        let title = target.title.as_deref().unwrap_or("").to_ascii_lowercase();
        let url = target.url.as_deref().unwrap_or("").to_ascii_lowercase();
        title.contains("codex") || url.contains("codex")
    });

    match preferred {
        Some(idx) => Some(pages.remove(idx)),
        None => pages.into_iter().next(),
    }
}

fn build_bridge_script() -> Result<String> {
    let binding_name = serde_json::to_string(BINDING_NAME)?;
    Ok(format!(
        r#"
(() => {{
  const bindingName = {binding_name};
  const root = window.__REDPEN_CODEX_APP__ || {{}};
  root.pending = root.pending || new Map();
  root.request = function(route, payload) {{
    return new Promise((resolve, reject) => {{
      const id = `${{Date.now()}}-${{Math.random().toString(36).slice(2)}}`;
      const timer = setTimeout(() => {{
        root.pending.delete(id);
        reject(new Error("redpen request timed out"));
      }}, 120000);
      root.pending.set(id, {{ resolve, reject, timer }});
      try {{
        window[bindingName](JSON.stringify({{ id, route, payload }}));
      }} catch (error) {{
        clearTimeout(timer);
        root.pending.delete(id);
        reject(error);
      }}
    }});
  }};
  root.resolve = function(id, result) {{
    const entry = root.pending.get(id);
    if (!entry) return;
    clearTimeout(entry.timer);
    root.pending.delete(id);
    entry.resolve(result);
  }};
  root.reject = function(id, message) {{
    const entry = root.pending.get(id);
    if (!entry) return;
    clearTimeout(entry.timer);
    root.pending.delete(id);
    entry.reject(new Error(message || "redpen request failed"));
  }};
  root.ready = true;
  window.__REDPEN_CODEX_APP__ = root;
}})();
"#
    ))
}

fn build_renderer_script(bridge_script: &str) -> String {
    format!("(() => {{\n{}\n{}\n}})();", bridge_script, INJECT_JS)
}

fn resolve_script(id: &str, value: &Value) -> Result<String> {
    Ok(format!(
        "window.__REDPEN_CODEX_APP__ && window.__REDPEN_CODEX_APP__.resolve({}, {});",
        serde_json::to_string(id)?,
        serde_json::to_string(value)?
    ))
}

fn reject_script(id: &str, message: &str) -> Result<String> {
    Ok(format!(
        "window.__REDPEN_CODEX_APP__ && window.__REDPEN_CODEX_APP__.reject({}, {});",
        serde_json::to_string(id)?,
        serde_json::to_string(message)?
    ))
}

impl CdpClient {
    async fn connect(ws_url: &str) -> Result<Self> {
        let (stream, _) = connect_async(ws_url)
            .await
            .with_context(|| format!("failed to connect CDP websocket {ws_url}"))?;
        let (write, read) = stream.split();
        Ok(Self {
            write,
            read,
            next_id: 0,
        })
    }

    async fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        let id = self.send(method, params).await?;

        while let Some(message) = self.read.next().await {
            let message = message?;
            if !message.is_text() {
                continue;
            }
            let response: Value = serde_json::from_str(message.to_text()?)?;
            if response.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            if let Some(error) = response.get("error") {
                bail!("CDP {method} failed: {error}");
            }
            return Ok(response.get("result").cloned().unwrap_or(Value::Null));
        }
        bail!("CDP websocket closed before {method} completed")
    }

    async fn send(&mut self, method: &str, params: Value) -> Result<u64> {
        self.next_id += 1;
        let id = self.next_id;
        let request = json!({
            "id": id,
            "method": method,
            "params": params,
        });
        self.write
            .send(Message::Text(request.to_string().into()))
            .await?;
        Ok(id)
    }

    async fn evaluate_no_wait(&mut self, expression: String) -> Result<()> {
        self.send(
            "Runtime.evaluate",
            json!({
                "expression": expression,
                "awaitPromise": false,
                "returnByValue": false,
                "allowUnsafeEvalBlockedByCSP": true,
            }),
        )
        .await?;
        Ok(())
    }

    async fn pump_bindings(&mut self, coach_script: PathBuf) -> Result<()> {
        while let Some(message) = self.read.next().await {
            let message = message?;
            if !message.is_text() {
                continue;
            }
            let event: Value = serde_json::from_str(message.to_text()?)?;
            if event.get("method").and_then(Value::as_str) != Some("Runtime.bindingCalled") {
                continue;
            }
            let params = event.get("params").cloned().unwrap_or(Value::Null);
            if params.get("name").and_then(Value::as_str) != Some(BINDING_NAME) {
                continue;
            }
            let Some(payload) = params.get("payload").and_then(Value::as_str) else {
                continue;
            };
            let request = match serde_json::from_str::<BridgeRequest>(payload) {
                Ok(request) => request,
                Err(err) => {
                    eprintln!("redpen bridge ignored invalid payload: {err}");
                    continue;
                }
            };

            let response = handle_bridge_request(&coach_script, &request).await;
            let expression = match response {
                Ok(value) => resolve_script(&request.id, &value)?,
                Err(err) => reject_script(&request.id, &err.to_string())?,
            };
            self.evaluate_no_wait(expression).await?;
        }
        Ok(())
    }
}

async fn handle_bridge_request(coach_script: &Path, request: &BridgeRequest) -> Result<Value> {
    match request.route.as_str() {
        "/coach" | "coach" => {
            let payload: CoachRequest = serde_json::from_value(request.payload.clone())
                .context("invalid /coach payload")?;
            run_coach(coach_script, payload).await
        }
        other => bail!("unknown redpen route: {other}"),
    }
}

fn truncate_for_json(value: &str, max_chars: usize) -> String {
    let mut out = value.chars().take(max_chars).collect::<String>();
    if value.chars().count() > max_chars {
        out.push_str("...");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(kind: &str, title: &str, url: &str, ws: Option<&str>) -> DebugTarget {
        DebugTarget {
            kind: kind.to_owned(),
            title: Some(title.to_owned()),
            url: Some(url.to_owned()),
            websocket_debugger_url: ws.map(str::to_owned),
        }
    }

    #[test]
    fn choose_target_prefers_codex_page() {
        let chosen = choose_target(vec![
            target("page", "Settings", "app://settings", Some("ws://settings")),
            target("page", "Codex", "app://codex", Some("ws://codex")),
            target(
                "service_worker",
                "Codex worker",
                "app://codex",
                Some("ws://worker"),
            ),
        ])
        .expect("target");

        assert_eq!(chosen.websocket_debugger_url.as_deref(), Some("ws://codex"));
    }

    #[test]
    fn choose_target_ignores_pages_without_websocket() {
        let chosen = choose_target(vec![
            target("page", "Codex", "app://codex", None),
            target("page", "Fallback", "app://fallback", Some("ws://fallback")),
        ])
        .expect("target");

        assert_eq!(
            chosen.websocket_debugger_url.as_deref(),
            Some("ws://fallback")
        );
    }

    #[test]
    fn bridge_script_exposes_request_api() {
        let script = build_bridge_script().expect("bridge script");

        assert!(script.contains(BINDING_NAME));
        assert!(script.contains("root.request"));
        assert!(script.contains("root.resolve"));
        assert!(script.contains("root.reject"));
    }

    #[test]
    fn renderer_script_wraps_top_level_return() {
        let bridge = build_bridge_script().expect("bridge script");
        let script = build_renderer_script(&bridge);

        assert!(script.starts_with("(() => {"));
        assert!(script.contains("window.__REDPEN_CODEX_APP_RENDERER__"));
        assert!(script.ends_with("})();"));
    }

    #[test]
    fn bundled_coach_files_are_written_together() {
        let dir =
            std::env::temp_dir().join(format!("redpen-codex-app-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);

        let coach = ensure_bundled_coach_in(&dir).expect("bundled coach");

        assert_eq!(coach, dir.join("coach_codex.sh"));
        assert!(dir.join("coach_codex.sh").exists());
        assert!(dir.join("coach_prompts.sh").exists());
        assert!(dir.join("render_diff.py").exists());
        assert!(
            fs::read_to_string(dir.join("coach_codex.sh"))
                .expect("coach")
                .contains("REDPEN_OUTPUT")
        );

        let _ = fs::remove_dir_all(&dir);
    }
}
