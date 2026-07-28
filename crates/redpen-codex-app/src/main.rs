#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::{
    collections::{HashMap, HashSet},
    env, fs,
    net::Ipv4Addr,
    path::{Path, PathBuf},
    process::Stdio,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
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
    sync::{Mutex, Semaphore, mpsc},
    time::{Instant, MissedTickBehavior, interval, sleep, timeout},
};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async, tungstenite::protocol::Message,
};

const DEFAULT_CHATGPT_APP: &str = "/Applications/ChatGPT.app";
const LEGACY_CODEX_APP: &str = "/Applications/Codex.app";
const BINDING_NAME: &str = "__redpenChatgptApp";
const CDP_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const CDP_INSTALL_TIMEOUT: Duration = Duration::from_secs(8);
const CDP_HEALTH_INTERVAL: Duration = Duration::from_secs(5);
const CDP_HEALTH_TIMEOUT: Duration = Duration::from_secs(5);
const CDP_WRITE_TIMEOUT: Duration = Duration::from_secs(3);
const CDP_RECONNECT_DELAY: Duration = Duration::from_millis(500);
const COACH_QUEUE_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_DELIVERED_TOMBSTONES: usize = 512;
const INJECT_JS: &str = include_str!("../../../assets/chatgpt-app/renderer-inject.js");
const BUNDLED_COACH_CODEX: &str =
    include_str!("../../../plugins/redpen-codex/shared/coach_codex.sh");
const BUNDLED_COACH_PROMPTS: &str =
    include_str!("../../../plugins/redpen-codex/shared/coach_prompts.sh");
const BUNDLED_RENDER_DIFF: &str =
    include_str!("../../../plugins/redpen-codex/shared/render_diff.py");

#[derive(Parser)]
#[command(name = "redpen-chatgpt-app")]
#[command(about = "Launch ChatGPT with redpen feedback injected through CDP.")]
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
    /// ChatGPT application bundle. --codex-app remains as a compatibility alias.
    #[arg(long, visible_alias = "codex-app")]
    chatgpt_app: Option<PathBuf>,

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
    id: Option<String>,
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

type BridgeOutcome = std::result::Result<Value, String>;

#[derive(Clone)]
enum JobState {
    Running,
    Finished(BridgeOutcome),
    Delivered(Instant),
}

#[derive(Clone)]
struct JobManager {
    coach_script: PathBuf,
    codex_bin: Option<PathBuf>,
    slots: Arc<Semaphore>,
    states: Arc<Mutex<HashMap<String, JobState>>>,
    completed_tx: mpsc::UnboundedSender<String>,
}

#[derive(Clone, Copy)]
struct PumpConfig {
    health_interval: Duration,
    health_timeout: Duration,
    delivery_timeout: Duration,
    watchdog_interval: Duration,
}

struct PendingHealth {
    command_id: u64,
    nonce: String,
    sent_at: Instant,
    evaluate_acked: bool,
    binding_acked: bool,
}

impl Default for PumpConfig {
    fn default() -> Self {
        Self {
            health_interval: CDP_HEALTH_INTERVAL,
            health_timeout: CDP_HEALTH_TIMEOUT,
            delivery_timeout: CDP_HEALTH_TIMEOUT,
            watchdog_interval: Duration::from_millis(250),
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Launch(args) => launch(args).await,
    }
}

async fn launch(args: LaunchArgs) -> Result<()> {
    let host_app = resolve_host_app(args.chatgpt_app);
    let host_executable = ensure_host_app(&host_app)?;
    let codex_bin = bundled_codex_bin(&host_app);
    ensure_host_not_running(&host_executable).await?;

    let coach_script = resolve_coach_script(args.coach_script)?;

    let debug_port = match args.debug_port {
        Some(port) => port,
        None => free_port().await?,
    };
    let launcher_instance_id = format!(
        "{}-{debug_port}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    );

    let mut host_process = spawn_host_app(&host_app, debug_port)
        .await
        .context("failed to launch ChatGPT")?;

    let (job_manager, mut completed_rx) = JobManager::new(coach_script, codex_bin);
    let mut supervisor = tokio::spawn(async move {
        supervise_cdp(
            debug_port,
            launcher_instance_id,
            job_manager,
            &mut completed_rx,
        )
        .await
    });
    tokio::select! {
        status = host_process.wait() => {
            supervisor.abort();
            let status = status?;
            if !status.success() {
                bail!("ChatGPT exited with status {}", status);
            }
        }
        supervisor_result = &mut supervisor => {
            let _ = host_process.kill().await;
            supervisor_result.context("redpen CDP supervisor panicked")??;
        }
    }

    Ok(())
}

async fn supervise_cdp(
    debug_port: u16,
    launcher_instance_id: String,
    job_manager: JobManager,
    completed_rx: &mut mpsc::UnboundedReceiver<String>,
) -> Result<()> {
    let mut generation = 0_u64;
    loop {
        generation += 1;
        let result = run_cdp_generation(
            debug_port,
            &launcher_instance_id,
            generation,
            &job_manager,
            completed_rx,
        )
        .await;
        match result {
            Ok(()) => eprintln!("redpen CDP generation {generation} closed; reconnecting"),
            Err(err) => {
                eprintln!("redpen CDP generation {generation} unhealthy: {err:#}; reconnecting")
            }
        }
        sleep(CDP_RECONNECT_DELAY).await;
    }
}

async fn run_cdp_generation(
    debug_port: u16,
    launcher_instance_id: &str,
    generation: u64,
    job_manager: &JobManager,
    completed_rx: &mut mpsc::UnboundedReceiver<String>,
) -> Result<()> {
    let target = wait_for_target(debug_port).await?;
    let target_id = target.id.as_deref().unwrap_or("unknown").to_owned();
    let ws_url = target
        .websocket_debugger_url
        .as_deref()
        .context("target did not expose a websocket debugger URL")?;
    let mut cdp = timeout(CDP_CONNECT_TIMEOUT, CdpClient::connect(ws_url))
        .await
        .context("timed out connecting to CDP target")??;
    let durable_deliveries = timeout(
        CDP_INSTALL_TIMEOUT,
        install_redpen(&mut cdp, launcher_instance_id),
    )
    .await
    .context("timed out installing redpen into CDP target")??;
    for request_id in durable_deliveries {
        job_manager.acknowledge(&request_id).await;
    }

    eprintln!("redpen CDP generation {generation} ready on target {target_id} (port {debug_port})");
    cdp.pump_bindings(job_manager, completed_rx, launcher_instance_id)
        .await
}

async fn install_redpen(client: &mut CdpClient, launcher_instance_id: &str) -> Result<Vec<String>> {
    let bridge_script = build_bridge_script(launcher_instance_id)?;
    let renderer_script = build_renderer_script(&bridge_script);

    client.call("Runtime.enable", json!({})).await?;
    client.call("Page.enable", json!({})).await?;
    client
        .call("Runtime.addBinding", json!({ "name": BINDING_NAME }))
        .await?;
    client
        .call(
            "Page.addScriptToEvaluateOnNewDocument",
            json!({ "source": renderer_script }),
        )
        .await?;
    let install_result = client
        .call(
            "Runtime.evaluate",
            json!({
                "expression": format!(
                    "{}\n{}",
                    build_renderer_script(&bridge_script),
                    bridge_status_expression(launcher_instance_id)?,
                ),
                "awaitPromise": false,
                "returnByValue": true,
                "allowUnsafeEvalBlockedByCSP": true,
            }),
        )
        .await?;
    parse_bridge_status(&install_result, launcher_instance_id)
}

async fn run_coach(
    coach_script: &Path,
    codex_bin: Option<&Path>,
    payload: CoachRequest,
) -> Result<Value> {
    let mut command = Command::new("bash");
    command
        .arg(coach_script)
        .env("REDPEN_OUTPUT", "structured")
        .env("REDPEN_HOST", "chatgpt-app")
        // The coach runs from a runtime dir without the plugin tree, so it
        // can't read the manifest version; hand it our own version for the
        // anonymous per-version install ping (see coach_codex.sh).
        .env("REDPEN_PLUGIN_VERSION", env!("CARGO_PKG_VERSION"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(codex_bin) = codex_bin {
        command.env("REDPEN_CODEX_BIN", codex_bin);
    }

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
    fs::create_dir_all(dir)
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
        .join("redpen-chatgpt-app")
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

fn resolve_host_app(explicit: Option<PathBuf>) -> PathBuf {
    if let Some(path) = explicit {
        return path;
    }
    let chatgpt = PathBuf::from(DEFAULT_CHATGPT_APP);
    if chatgpt.exists() {
        return chatgpt;
    }
    let codex = PathBuf::from(LEGACY_CODEX_APP);
    if codex.exists() {
        return codex;
    }
    chatgpt
}

fn ensure_host_app(host_app: &Path) -> Result<PathBuf> {
    for executable in ["ChatGPT", "Codex"] {
        let macos_bin = host_app.join("Contents/MacOS").join(executable);
        if macos_bin.exists() {
            return Ok(macos_bin);
        }
    }
    bail!(
        "ChatGPT executable not found in {}. Pass --chatgpt-app if your install lives elsewhere.",
        host_app.display()
    )
}

fn bundled_codex_bin(host_app: &Path) -> Option<PathBuf> {
    let codex = host_app.join("Contents/Resources/codex");
    codex.is_file().then_some(codex)
}

async fn ensure_host_not_running(macos_bin: &Path) -> Result<()> {
    let output = Command::new("ps")
        .args(["-axo", "command"])
        .output()
        .await
        .context("failed to inspect running processes")?;
    let commands = String::from_utf8_lossy(&output.stdout);
    let marker = macos_bin.to_string_lossy();
    if commands.lines().any(|line| line.contains(marker.as_ref())) {
        bail!(
            "ChatGPT is already running. Quit it first, then launch through redpen so remote debugging can be enabled."
        );
    }
    Ok(())
}

async fn spawn_host_app(host_app: &Path, debug_port: u16) -> Result<tokio::process::Child> {
    let mut command = Command::new("open");
    command
        .arg("-W")
        .arg("-n")
        .arg(host_app)
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
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()?;
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

    Err(last_err.unwrap_or_else(|| anyhow!("timed out waiting for ChatGPT debug target")))
}

fn choose_target(targets: Vec<DebugTarget>) -> Option<DebugTarget> {
    let mut pages = targets
        .into_iter()
        .filter(|target| {
            if target.kind != "page" || target.websocket_debugger_url.is_none() {
                return false;
            }
            let url = target.url.as_deref().unwrap_or("").to_ascii_lowercase();
            !url.contains("avatar-overlay") && !url.contains("avatar-overlay-composition-surface")
        })
        .collect::<Vec<_>>();

    let main_app = pages.iter().position(|target| {
        target
            .url
            .as_deref()
            .unwrap_or("")
            .eq_ignore_ascii_case("app://-/index.html")
    });
    match main_app {
        Some(idx) => Some(pages.remove(idx)),
        None => {
            let preferred = pages.iter().position(|target| {
                let title = target.title.as_deref().unwrap_or("").to_ascii_lowercase();
                let url = target.url.as_deref().unwrap_or("").to_ascii_lowercase();
                title.contains("chatgpt") || url.contains("chatgpt")
            });
            if let Some(idx) = preferred {
                return Some(pages.remove(idx));
            }

            let legacy = pages.iter().position(|target| {
                let title = target.title.as_deref().unwrap_or("").to_ascii_lowercase();
                let url = target.url.as_deref().unwrap_or("").to_ascii_lowercase();
                title.contains("codex") || url.contains("codex")
            });
            match legacy {
                Some(idx) => Some(pages.remove(idx)),
                None => pages.into_iter().next(),
            }
        }
    }
}

fn build_bridge_script(launcher_instance_id: &str) -> Result<String> {
    let binding_name = serde_json::to_string(BINDING_NAME)?;
    let launcher_instance_id = serde_json::to_string(launcher_instance_id)?;
    Ok(format!(
        r#"
(() => {{
  if (window !== window.top) return;
  const bindingName = {binding_name};
  const instanceId = {launcher_instance_id};
  const outboxStorageKey = "redpen.chatgpt-app.bridge-outbox.v1";
  const root = window.__REDPEN_CHATGPT_APP__ || {{}};
  const resetOutbox = root.instanceId !== instanceId;
  if (resetOutbox && root.pending instanceof Map) {{
    for (const entry of root.pending.values()) {{
      clearTimeout(entry.timer);
      const error = new Error("redpen launcher restarted");
      error.redpenTerminal = true;
      entry.reject(error);
    }}
  }}
  root.pending =
    !resetOutbox && root.pending instanceof Map ? root.pending : new Map();
  if (resetOutbox) {{
    let saved = null;
    try {{
      saved = JSON.parse(localStorage.getItem(outboxStorageKey) || "null");
    }} catch (_error) {{}}
    root.outbox = new Map(
      saved?.instanceId === instanceId && Array.isArray(saved.requests)
        ? saved.requests.map((request) => [request.id, request])
        : [],
    );
    root.inbox = new Map(
      saved?.instanceId === instanceId && Array.isArray(saved.results)
        ? saved.results
        : [],
    );
    root.acknowledged = new Set(
      saved?.instanceId === instanceId && Array.isArray(saved.acknowledged)
        ? saved.acknowledged
        : [],
    );
    root.nonDurableInbox = new Set();
    root.nonDurableAcknowledged = new Set();
  }}
  if (!(root.outbox instanceof Map)) root.outbox = new Map();
  if (!(root.inbox instanceof Map)) root.inbox = new Map();
  if (!(root.acknowledged instanceof Set)) root.acknowledged = new Set();
  if (!(root.nonDurableInbox instanceof Set)) root.nonDurableInbox = new Set();
  if (!(root.nonDurableAcknowledged instanceof Set)) {{
    root.nonDurableAcknowledged = new Set();
  }}
  root.instanceId = instanceId;
  root.persistState = function() {{
    try {{
      localStorage.setItem(
        outboxStorageKey,
        JSON.stringify({{
          instanceId,
          requests: Array.from(root.outbox.values()),
          results: Array.from(root.inbox),
          acknowledged: Array.from(root.acknowledged),
        }}),
      );
      root.nonDurableInbox.clear();
      root.nonDurableAcknowledged.clear();
      return true;
    }} catch (_error) {{
      return false;
    }}
  }};
  if (resetOutbox) root.persistState();
  root.createRequestId = function() {{
    const randomPart =
      globalThis.crypto?.randomUUID?.() ||
      `${{Math.random().toString(36).slice(2)}}-${{Math.random().toString(36).slice(2)}}`;
    return `${{Date.now()}}-${{randomPart}}`;
  }};
  root.send = function(request) {{
    try {{
      window[bindingName](JSON.stringify(request));
      return true;
    }} catch (_error) {{
      return false;
    }}
  }};
  root.ping = function(nonce) {{
    if (
      root.instanceId !== instanceId ||
      typeof window[bindingName] !== "function"
    ) {{
      return false;
    }}
    try {{
      window[bindingName](
        JSON.stringify({{
          id: nonce,
          route: "/__redpen_health",
          payload: {{ nonce }},
        }}),
      );
      return true;
    }} catch (_error) {{
      return false;
    }}
  }};
  root.flush = function() {{
    for (const request of root.outbox.values()) {{
      if (!root.inbox.has(request.id) || root.nonDurableInbox.has(request.id)) {{
        root.send(request);
      }}
    }}
  }};
  if (!root.flushTimer) {{
    root.flushTimer = setInterval(() => root.flush(), 5000);
  }}
  root.settle = function(id) {{
    const entry = root.pending.get(id);
    const outcome = root.inbox.get(id);
    if (!entry || !outcome) return false;
    clearTimeout(entry.timer);
    root.pending.delete(id);
    if (outcome.ok) {{
      entry.resolve(outcome.value);
    }} else {{
      const error = new Error(outcome.message || "redpen request failed");
      error.redpenTerminal = true;
      entry.reject(error);
    }}
    return true;
  }};
  root.request = function(route, payload, requestId) {{
    const id =
      typeof requestId === "string" && requestId
        ? requestId
        : root.createRequestId();
    const existing = root.pending.get(id);
    if (existing) return existing.promise;

    let resolvePending;
    let rejectPending;
    const promise = new Promise((resolve, reject) => {{
      resolvePending = resolve;
      rejectPending = reject;
    }});
    const timer = setTimeout(() => {{
      root.pending.delete(id);
      const error = new Error("redpen request timed out");
      error.redpenPending = true;
      rejectPending(error);
    }}, 120000);
    root.pending.set(id, {{
      promise,
      resolve: resolvePending,
      reject: rejectPending,
      timer,
    }});

    if (root.inbox.has(id)) {{
      queueMicrotask(() => root.settle(id));
      return promise;
    }}
    if (!root.outbox.has(id)) {{
      root.outbox.set(id, {{ id, route, payload }});
      root.persistState();
    }}
    root.send(root.outbox.get(id));
    return promise;
  }};
  root.deliver = function(id, outcome) {{
    if (
      typeof id !== "string" ||
      !id ||
      !outcome ||
      typeof outcome.ok !== "boolean"
    ) {{
      return false;
    }}
    if (root.acknowledged.has(id)) {{
      return root.nonDurableAcknowledged.has(id)
        ? root.persistState()
        : true;
    }}
    root.inbox.set(id, outcome);
    root.nonDurableInbox.add(id);
    const persisted = root.persistState();
    root.settle(id);
    return persisted;
  }};
  root.ack = function(id) {{
    if (root.nonDurableInbox.has(id) && !root.persistState()) {{
      return false;
    }}
    const entry = root.pending.get(id);
    if (entry) clearTimeout(entry.timer);
    root.pending.delete(id);
    root.outbox.delete(id);
    root.inbox.delete(id);
    root.nonDurableInbox.delete(id);
    root.acknowledged.delete(id);
    root.acknowledged.add(id);
    root.nonDurableAcknowledged.add(id);
    while (root.acknowledged.size > 512) {{
      const oldestId = root.acknowledged.values().next().value;
      root.acknowledged.delete(oldestId);
      root.nonDurableAcknowledged.delete(oldestId);
    }}
    return root.persistState();
  }};
  root.ready = true;
  window.__REDPEN_CHATGPT_APP__ = root;
  root.flush();
}})();
"#
    ))
}

fn build_renderer_script(bridge_script: &str) -> String {
    format!(
        "(() => {{\nif (window !== window.top) return;\n{}\n{}\n}})();",
        bridge_script, INJECT_JS
    )
}

fn delivery_script(id: &str, outcome: &BridgeOutcome) -> Result<String> {
    let outcome = match outcome {
        Ok(value) => json!({ "ok": true, "value": value }),
        Err(message) => json!({ "ok": false, "message": message }),
    };
    Ok(format!(
        "Boolean(window.__REDPEN_CHATGPT_APP__?.deliver?.({}, {}))",
        serde_json::to_string(id)?,
        serde_json::to_string(&outcome)?
    ))
}

fn bridge_status_expression(launcher_instance_id: &str) -> Result<String> {
    let instance_id = serde_json::to_string(launcher_instance_id)?;
    let binding_name = serde_json::to_string(BINDING_NAME)?;
    Ok(format!(
        r#"(() => {{
  const root = window.__REDPEN_CHATGPT_APP__;
  return {{
    ready: Boolean(
      root?.ready &&
      root?.instanceId === {instance_id} &&
      typeof window[{binding_name}] === "function"
    ),
    instanceId: root?.instanceId || null,
    bindingType: typeof window[{binding_name}],
    inboxIds:
      root?.inbox instanceof Map
        ? Array.from(root.inbox.keys()).filter(
            (id) => !root?.nonDurableInbox?.has?.(id),
          )
        : [],
    acknowledgedIds:
      root?.acknowledged instanceof Set
        ? Array.from(root.acknowledged).filter(
            (id) => !root?.nonDurableAcknowledged?.has?.(id),
          )
        : [],
  }};
}})()"#
    ))
}

fn bridge_health_expression(launcher_instance_id: &str, nonce: &str) -> Result<String> {
    let instance_id = serde_json::to_string(launcher_instance_id)?;
    let nonce = serde_json::to_string(nonce)?;
    Ok(format!(
        "Boolean(window.__REDPEN_CHATGPT_APP__?.ready && \
         window.__REDPEN_CHATGPT_APP__?.instanceId === {instance_id} && \
         window.__REDPEN_CHATGPT_APP__?.ping?.({nonce}))"
    ))
}

fn parse_bridge_status(result: &Value, expected_instance_id: &str) -> Result<Vec<String>> {
    if let Some(exception) = result.get("exceptionDetails") {
        bail!("redpen bridge injection threw an exception: {exception}");
    }
    let status = result
        .pointer("/result/value")
        .context("redpen bridge injection did not return a status value")?;
    if status.get("ready").and_then(Value::as_bool) != Some(true)
        || status.get("instanceId").and_then(Value::as_str) != Some(expected_instance_id)
        || status.get("bindingType").and_then(Value::as_str) != Some("function")
    {
        bail!("redpen bridge did not become ready: {status}");
    }
    let mut seen = HashSet::new();
    Ok(["inboxIds", "acknowledgedIds"]
        .into_iter()
        .filter_map(|key| status.get(key).and_then(Value::as_array))
        .flatten()
        .filter_map(Value::as_str)
        .filter(|id| seen.insert((*id).to_owned()))
        .map(str::to_owned)
        .collect())
}

impl JobManager {
    fn new(
        coach_script: PathBuf,
        codex_bin: Option<PathBuf>,
    ) -> (Self, mpsc::UnboundedReceiver<String>) {
        let (completed_tx, completed_rx) = mpsc::unbounded_channel();
        (
            Self {
                coach_script,
                codex_bin,
                slots: Arc::new(Semaphore::new(4)),
                states: Arc::new(Mutex::new(HashMap::new())),
                completed_tx,
            },
            completed_rx,
        )
    }

    async fn submit(&self, request: BridgeRequest) {
        let request_id = request.id.clone();
        let should_start = {
            let mut states = self.states.lock().await;
            match states.get(&request_id) {
                Some(JobState::Running) => false,
                Some(JobState::Finished(_)) => {
                    let _ = self.completed_tx.send(request_id);
                    return;
                }
                Some(JobState::Delivered(_)) => false,
                None => {
                    states.insert(request_id.clone(), JobState::Running);
                    true
                }
            }
        };
        if !should_start {
            return;
        }

        let manager = self.clone();
        tokio::spawn(async move {
            let started = Instant::now();
            eprintln!("redpen request {request_id} accepted");
            let outcome =
                match timeout(COACH_QUEUE_TIMEOUT, manager.slots.clone().acquire_owned()).await {
                    Ok(Ok(_permit)) => handle_bridge_request(
                        &manager.coach_script,
                        manager.codex_bin.as_deref(),
                        &request,
                    )
                    .await
                    .map_err(|err| err.to_string()),
                    Ok(Err(err)) => Err(format!("redpen coach queue closed: {err}")),
                    Err(_) => Err("redpen coach queue is busy; retry this prompt".to_owned()),
                };
            eprintln!(
                "redpen request {request_id} finished in {} ms ({})",
                started.elapsed().as_millis(),
                if outcome.is_ok() { "ok" } else { "error" }
            );
            manager
                .states
                .lock()
                .await
                .insert(request_id.clone(), JobState::Finished(outcome));
            let _ = manager.completed_tx.send(request_id);
        });
    }

    async fn outcome(&self, request_id: &str) -> Option<BridgeOutcome> {
        match self.states.lock().await.get(request_id) {
            Some(JobState::Finished(outcome)) => Some(outcome.clone()),
            _ => None,
        }
    }

    async fn acknowledge(&self, request_id: &str) {
        let mut states = self.states.lock().await;
        if matches!(states.get(request_id), Some(JobState::Running)) {
            return;
        }
        states.insert(request_id.to_owned(), JobState::Delivered(Instant::now()));

        let delivered_count = states
            .values()
            .filter(|state| matches!(state, JobState::Delivered(_)))
            .count();
        if delivered_count > MAX_DELIVERED_TOMBSTONES {
            let mut delivered = states
                .iter()
                .filter_map(|(id, state)| match state {
                    JobState::Delivered(at) => Some((id.clone(), *at)),
                    _ => None,
                })
                .collect::<Vec<_>>();
            delivered.sort_by_key(|(_, at)| *at);
            for (id, _) in delivered
                .into_iter()
                .take(delivered_count - MAX_DELIVERED_TOMBSTONES)
            {
                states.remove(&id);
            }
        }
        eprintln!("redpen request {request_id} acknowledged");
    }
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

    async fn send_with_deadline(&mut self, method: &str, params: Value) -> Result<u64> {
        timeout(CDP_WRITE_TIMEOUT, self.send(method, params))
            .await
            .with_context(|| format!("timed out writing CDP {method} command"))?
    }

    async fn pump_bindings(
        &mut self,
        job_manager: &JobManager,
        completed_rx: &mut mpsc::UnboundedReceiver<String>,
        launcher_instance_id: &str,
    ) -> Result<()> {
        self.pump_bindings_with_config(
            job_manager,
            completed_rx,
            launcher_instance_id,
            PumpConfig::default(),
        )
        .await
    }

    async fn pump_bindings_with_config(
        &mut self,
        job_manager: &JobManager,
        completed_rx: &mut mpsc::UnboundedReceiver<String>,
        launcher_instance_id: &str,
        config: PumpConfig,
    ) -> Result<()> {
        let mut health_tick = interval(config.health_interval);
        health_tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
        let mut watchdog_tick = interval(config.watchdog_interval);
        watchdog_tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
        let mut health_pending: Option<PendingHealth> = None;
        let mut health_sequence = 0_u64;
        let mut delivery_commands = HashMap::<u64, (String, Instant)>::new();
        let mut delivering = HashSet::<String>::new();

        self.send_with_deadline(
            "Runtime.evaluate",
            json!({
                "expression": "window.__REDPEN_CHATGPT_APP__?.flush?.(); true",
                "awaitPromise": false,
                "returnByValue": true,
                "allowUnsafeEvalBlockedByCSP": true,
            }),
        )
        .await?;

        loop {
            tokio::select! {
                message = self.read.next() => {
                    let Some(message) = message else {
                        bail!("CDP websocket closed");
                    };
                    let message = message?;
                    if message.is_close() {
                        bail!("CDP websocket closed by peer");
                    }
                    if !message.is_text() {
                        continue;
                    }
                    let envelope: Value = serde_json::from_str(message.to_text()?)?;

                    if let Some(response_id) = envelope.get("id").and_then(Value::as_u64) {
                        if health_pending
                            .as_ref()
                            .is_some_and(|health| health.command_id == response_id)
                        {
                            if !evaluate_returned_true(&envelope) {
                                bail!("redpen bridge health check was not acknowledged: {envelope}");
                            }
                            let health = health_pending.as_mut().expect("health command");
                            health.evaluate_acked = true;
                            if health.binding_acked {
                                health_pending = None;
                            }
                        }

                        if let Some((request_id, _)) = delivery_commands.remove(&response_id) {
                            delivering.remove(&request_id);
                            if evaluate_returned_true(&envelope) {
                                job_manager.acknowledge(&request_id).await;
                            } else {
                                bail!(
                                    "redpen request {request_id} durable delivery was not acknowledged: {envelope}"
                                );
                            }
                        }
                        continue;
                    }

                    let method = envelope.get("method").and_then(Value::as_str);
                    if method != Some("Runtime.bindingCalled") {
                        continue;
                    }

                    let params = envelope.get("params").cloned().unwrap_or(Value::Null);
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
                    if request.route == "/__redpen_health" {
                        let nonce_matches_payload = request
                            .payload
                            .get("nonce")
                            .and_then(Value::as_str)
                            == Some(request.id.as_str());
                        if let Some(health) = health_pending
                            .as_mut()
                            .filter(|health| {
                                nonce_matches_payload && health.nonce == request.id
                            })
                        {
                            health.binding_acked = true;
                            if health.evaluate_acked {
                                health_pending = None;
                            }
                        }
                        continue;
                    }
                    job_manager.submit(request).await;
                }
                _ = health_tick.tick(), if health_pending.is_none() => {
                    health_sequence += 1;
                    let nonce =
                        format!("{launcher_instance_id}-health-{health_sequence}");
                    let health_expression =
                        bridge_health_expression(launcher_instance_id, &nonce)?;
                    let command_id = self
                        .send_with_deadline(
                            "Runtime.evaluate",
                            json!({
                                "expression": health_expression.as_str(),
                                "returnByValue": true,
                                "allowUnsafeEvalBlockedByCSP": true,
                            }),
                        )
                        .await?;
                    health_pending = Some(PendingHealth {
                        command_id,
                        nonce,
                        sent_at: Instant::now(),
                        evaluate_acked: false,
                        binding_acked: false,
                    });
                }
                _ = watchdog_tick.tick() => {
                    if health_pending.as_ref().is_some_and(
                        |health| health.sent_at.elapsed() >= config.health_timeout,
                    ) {
                        bail!("CDP full-duplex health check was not acknowledged");
                    }
                    if delivery_commands.values().any(
                        |(_, sent_at)| sent_at.elapsed() >= config.delivery_timeout,
                    ) {
                        bail!("CDP durable delivery command was not acknowledged");
                    }
                }
                Some(request_id) = completed_rx.recv() => {
                    if delivering.contains(&request_id) {
                        continue;
                    }
                    let Some(outcome) = job_manager.outcome(&request_id).await else {
                        continue;
                    };
                    let expression = delivery_script(&request_id, &outcome)?;
                    let command_id = self
                        .send_with_deadline(
                            "Runtime.evaluate",
                            json!({
                                "expression": expression,
                                "awaitPromise": false,
                                "returnByValue": true,
                                "allowUnsafeEvalBlockedByCSP": true,
                            }),
                        )
                        .await?;
                    delivery_commands.insert(command_id, (request_id.clone(), Instant::now()));
                    delivering.insert(request_id);
                }
            }
        }
    }
}

fn evaluate_returned_true(envelope: &Value) -> bool {
    envelope.get("error").is_none()
        && envelope.pointer("/result/exceptionDetails").is_none()
        && envelope
            .pointer("/result/result/value")
            .and_then(Value::as_bool)
            == Some(true)
}

async fn handle_bridge_request(
    coach_script: &Path,
    codex_bin: Option<&Path>,
    request: &BridgeRequest,
) -> Result<Value> {
    match request.route.as_str() {
        "/coach" | "coach" => {
            let payload: CoachRequest = serde_json::from_value(request.payload.clone())
                .context("invalid /coach payload")?;
            run_coach(coach_script, codex_bin, payload).await
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

    async fn fake_delivery_server(ack_delivery: bool) -> (String, tokio::task::JoinHandle<bool>) {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .expect("listener");
        let address = listener.local_addr().expect("listener address");
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("connection");
            let mut websocket = tokio_tungstenite::accept_async(stream)
                .await
                .expect("websocket handshake");
            let binding_payload = json!({
                "id": "replayed-request-id",
                "route": "/coach",
                "payload": {
                    "prompt": "hello",
                    "requestId": "renderer-request-id",
                },
            })
            .to_string();
            let mut binding_sent = false;
            let mut delivery_seen = false;
            let mut silent = false;
            let mut health_sequence = 0_u64;

            while let Some(message) = websocket.next().await {
                let Ok(message) = message else {
                    break;
                };
                if !message.is_text() {
                    continue;
                }
                let command: Value =
                    serde_json::from_str(message.to_text().expect("text")).expect("CDP command");
                let id = command.get("id").and_then(Value::as_u64).expect("id");
                let expression = command
                    .pointer("/params/expression")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let is_delivery = expression.contains(".deliver?.");
                if is_delivery {
                    delivery_seen = true;
                    if !ack_delivery {
                        silent = true;
                    }
                }
                if silent {
                    continue;
                }

                websocket
                    .send(Message::Text(
                        json!({
                            "id": id,
                            "result": {
                                "result": {
                                    "type": "boolean",
                                    "value": true,
                                },
                            },
                        })
                        .to_string()
                        .into(),
                    ))
                    .await
                    .expect("CDP response");

                if expression.contains(".ping?.") {
                    health_sequence += 1;
                    let nonce = format!("test-instance-health-{health_sequence}");
                    websocket
                        .send(Message::Text(
                            json!({
                                "method": "Runtime.bindingCalled",
                                "params": {
                                    "name": BINDING_NAME,
                                    "payload": json!({
                                        "id": nonce.as_str(),
                                        "route": "/__redpen_health",
                                        "payload": {
                                            "nonce": nonce.as_str(),
                                        },
                                    })
                                    .to_string(),
                                    "executionContextId": 1,
                                },
                            })
                            .to_string()
                            .into(),
                        ))
                        .await
                        .expect("health binding event");
                }

                if !binding_sent {
                    binding_sent = true;
                    websocket
                        .send(Message::Text(
                            json!({
                                "method": "Runtime.bindingCalled",
                                "params": {
                                    "name": BINDING_NAME,
                                    "payload": binding_payload,
                                    "executionContextId": 1,
                                },
                            })
                            .to_string()
                            .into(),
                        ))
                        .await
                        .expect("binding event");
                }

                if is_delivery {
                    websocket.close(None).await.expect("close websocket");
                    break;
                }
            }
            delivery_seen
        });
        (format!("ws://{address}"), server)
    }

    fn target(kind: &str, title: &str, url: &str, ws: Option<&str>) -> DebugTarget {
        DebugTarget {
            id: Some(format!("{kind}-{title}")),
            kind: kind.to_owned(),
            title: Some(title.to_owned()),
            url: Some(url.to_owned()),
            websocket_debugger_url: ws.map(str::to_owned),
        }
    }

    #[test]
    fn choose_target_prefers_chatgpt_page() {
        let chosen = choose_target(vec![
            target("page", "Settings", "app://settings", Some("ws://settings")),
            target("page", "Codex", "app://codex", Some("ws://codex")),
            target("page", "ChatGPT", "app://chatgpt", Some("ws://chatgpt")),
        ])
        .expect("target");

        assert_eq!(
            chosen.websocket_debugger_url.as_deref(),
            Some("ws://chatgpt")
        );
    }

    #[test]
    fn choose_target_supports_legacy_codex_page() {
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
    fn choose_target_prefers_exact_app_page_over_chatgpt_web_content() {
        let chosen = choose_target(vec![
            target(
                "page",
                "ChatGPT",
                "https://chatgpt.com/",
                Some("ws://web-content"),
            ),
            target("page", "Codex", "app://-/index.html", Some("ws://main")),
        ])
        .expect("target");

        assert_eq!(chosen.websocket_debugger_url.as_deref(), Some("ws://main"));
    }

    #[test]
    fn choose_target_ignores_codex_avatar_overlay() {
        let chosen = choose_target(vec![
            target(
                "page",
                "Codex",
                "app://-/index.html?initialRoute=%2Favatar-overlay",
                Some("ws://overlay"),
            ),
            target("page", "Codex", "app://-/index.html", Some("ws://main")),
        ])
        .expect("target");

        assert_eq!(chosen.websocket_debugger_url.as_deref(), Some("ws://main"));
    }

    #[test]
    fn choose_target_waits_when_only_avatar_overlay_exists() {
        let chosen = choose_target(vec![target(
            "page",
            "Codex",
            "app://-/index.html?initialRoute=%2Favatar-overlay",
            Some("ws://overlay"),
        )]);

        assert!(chosen.is_none());
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
        let script = build_bridge_script("test-instance").expect("bridge script");

        assert!(script.contains(BINDING_NAME));
        assert!(script.contains("root.request"));
        assert!(script.contains("root.deliver"));
        assert!(script.contains("root.ack"));
        assert!(script.contains("root.outbox"));
        assert!(script.contains("root.inbox"));
        assert!(script.contains("root.flush"));
        assert!(script.contains("test-instance"));
    }

    #[test]
    fn bridge_status_only_accepts_verified_instance_and_collects_durable_ids() {
        let status = json!({
            "result": {
                "type": "object",
                "value": {
                    "ready": true,
                    "instanceId": "test-instance",
                    "bindingType": "function",
                    "inboxIds": ["inbox-id", "duplicate-id"],
                    "acknowledgedIds": ["duplicate-id", "ack-id"],
                },
            },
        });
        assert_eq!(
            parse_bridge_status(&status, "test-instance").expect("status"),
            vec!["inbox-id", "duplicate-id", "ack-id"]
        );

        let wrong_instance = parse_bridge_status(&status, "other-instance")
            .expect_err("wrong launcher instance must fail");
        assert!(wrong_instance.to_string().contains("did not become ready"));
    }

    #[test]
    fn delivery_ack_requires_explicit_true_result() {
        assert!(evaluate_returned_true(&json!({
            "id": 1,
            "result": {
                "result": {
                    "type": "boolean",
                    "value": true,
                },
            },
        })));
        assert!(!evaluate_returned_true(&json!({
            "id": 1,
            "result": {
                "result": {
                    "type": "undefined",
                },
            },
        })));
        assert!(!evaluate_returned_true(&json!({
            "id": 1,
            "result": {
                "result": {
                    "type": "boolean",
                    "value": true,
                },
                "exceptionDetails": {
                    "text": "boom",
                },
            },
        })));
    }

    #[tokio::test]
    async fn pump_detects_established_but_unresponsive_websocket() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .expect("listener");
        let address = listener.local_addr().expect("listener address");
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("connection");
            let mut websocket = tokio_tungstenite::accept_async(stream)
                .await
                .expect("websocket handshake");

            // Keep reading commands so the TCP connection remains established, but never
            // acknowledge them. This reproduces the observed half-alive CDP session.
            while let Some(message) = websocket.next().await {
                if message.expect("websocket message").is_close() {
                    break;
                }
            }
        });

        let mut client = CdpClient::connect(&format!("ws://{address}"))
            .await
            .expect("client");
        let (jobs, mut completed_rx) = JobManager::new(PathBuf::from("/unused"), None);
        let result = timeout(
            Duration::from_secs(1),
            client.pump_bindings_with_config(
                &jobs,
                &mut completed_rx,
                "test-instance",
                PumpConfig {
                    health_interval: Duration::from_millis(10),
                    health_timeout: Duration::from_millis(40),
                    delivery_timeout: Duration::from_millis(40),
                    watchdog_interval: Duration::from_millis(5),
                },
            ),
        )
        .await
        .expect("pump should not hang")
        .expect_err("unresponsive websocket must be rejected");

        assert!(
            result
                .to_string()
                .contains("full-duplex health check was not acknowledged")
        );
        server.abort();
    }

    #[tokio::test]
    async fn pump_rejects_runtime_that_does_not_emit_binding_events() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .expect("listener");
        let address = listener.local_addr().expect("listener address");
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("connection");
            let mut websocket = tokio_tungstenite::accept_async(stream)
                .await
                .expect("websocket handshake");
            while let Some(message) = websocket.next().await {
                let Ok(message) = message else {
                    break;
                };
                if !message.is_text() {
                    continue;
                }
                let command: Value =
                    serde_json::from_str(message.to_text().expect("text")).expect("CDP command");
                let id = command.get("id").and_then(Value::as_u64).expect("id");
                websocket
                    .send(Message::Text(
                        json!({
                            "id": id,
                            "result": {
                                "result": {
                                    "type": "boolean",
                                    "value": true,
                                },
                            },
                        })
                        .to_string()
                        .into(),
                    ))
                    .await
                    .expect("CDP response");
            }
        });

        let mut client = CdpClient::connect(&format!("ws://{address}"))
            .await
            .expect("client");
        let (jobs, mut completed_rx) = JobManager::new(PathBuf::from("/unused"), None);
        let result = timeout(
            Duration::from_secs(1),
            client.pump_bindings_with_config(
                &jobs,
                &mut completed_rx,
                "test-instance",
                PumpConfig {
                    health_interval: Duration::from_millis(10),
                    health_timeout: Duration::from_millis(40),
                    delivery_timeout: Duration::from_millis(40),
                    watchdog_interval: Duration::from_millis(5),
                },
            ),
        )
        .await
        .expect("pump should not hang")
        .expect_err("missing binding notification must be rejected");

        assert!(
            result
                .to_string()
                .contains("full-duplex health check was not acknowledged")
        );
        server.abort();
    }

    #[tokio::test]
    async fn job_manager_deduplicates_until_delivery_is_acknowledged() {
        let dir =
            std::env::temp_dir().join(format!("redpen-job-manager-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("test directory");
        let coach = dir.join("coach.sh");
        fs::write(
            &coach,
            r#"IFS= read -r _input || true
printf '1\n' >> "$(dirname "$0")/count"
sleep 0.05
printf '%s\n' '{"status":"ok"}'
"#,
        )
        .expect("coach script");

        let request = || BridgeRequest {
            id: "stable-request-id".to_owned(),
            route: "/coach".to_owned(),
            payload: json!({
                "prompt": "hello",
                "requestId": "renderer-request-id",
            }),
        };
        let (jobs, mut completed_rx) = JobManager::new(coach, None);

        jobs.submit(request()).await;
        jobs.submit(request()).await;
        assert_eq!(
            timeout(Duration::from_secs(1), completed_rx.recv())
                .await
                .expect("job timeout")
                .as_deref(),
            Some("stable-request-id")
        );
        assert!(jobs.outcome("stable-request-id").await.is_some());
        assert_eq!(
            fs::read_to_string(dir.join("count"))
                .expect("counter")
                .lines()
                .count(),
            1
        );

        // A replay after completion must reuse the cached result rather than run
        // the coach again. The state is only released after the CDP delivery ACK.
        jobs.submit(request()).await;
        assert_eq!(
            timeout(Duration::from_secs(1), completed_rx.recv())
                .await
                .expect("cached result timeout")
                .as_deref(),
            Some("stable-request-id")
        );
        assert_eq!(
            fs::read_to_string(dir.join("count"))
                .expect("counter")
                .lines()
                .count(),
            1
        );

        jobs.acknowledge("stable-request-id").await;
        assert!(jobs.outcome("stable-request-id").await.is_none());
        jobs.submit(request()).await;
        assert!(
            timeout(Duration::from_millis(100), completed_rx.recv())
                .await
                .is_err()
        );
        assert_eq!(
            fs::read_to_string(dir.join("count"))
                .expect("counter")
                .lines()
                .count(),
            1
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn finished_job_survives_generation_loss_and_is_delivered_after_replay() {
        let dir =
            std::env::temp_dir().join(format!("redpen-generation-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("test directory");
        let coach = dir.join("coach.sh");
        fs::write(
            &coach,
            r#"IFS= read -r _input || true
printf '1\n' >> "$(dirname "$0")/count"
sleep 0.02
printf '%s\n' '{"status":"ok"}'
"#,
        )
        .expect("coach script");
        let (jobs, mut completed_rx) = JobManager::new(coach, None);
        let config = PumpConfig {
            health_interval: Duration::from_millis(20),
            health_timeout: Duration::from_millis(100),
            delivery_timeout: Duration::from_millis(100),
            watchdog_interval: Duration::from_millis(5),
        };

        let (first_url, first_server) = fake_delivery_server(false).await;
        let mut first_client = CdpClient::connect(&first_url).await.expect("first client");
        let first_error = timeout(
            Duration::from_secs(2),
            first_client.pump_bindings_with_config(
                &jobs,
                &mut completed_rx,
                "test-instance",
                config,
            ),
        )
        .await
        .expect("first generation timeout")
        .expect_err("first generation must become unhealthy");
        assert!(first_error.to_string().contains("not acknowledged"));
        assert!(jobs.outcome("replayed-request-id").await.is_some());
        drop(first_client);
        assert!(
            timeout(Duration::from_secs(1), first_server)
                .await
                .expect("first server timeout")
                .expect("first server")
        );

        let (second_url, second_server) = fake_delivery_server(true).await;
        let mut second_client = CdpClient::connect(&second_url)
            .await
            .expect("second client");
        let _ = timeout(
            Duration::from_secs(2),
            second_client.pump_bindings_with_config(
                &jobs,
                &mut completed_rx,
                "test-instance",
                config,
            ),
        )
        .await
        .expect("second generation timeout")
        .expect_err("server closes after durable delivery");
        assert!(
            timeout(Duration::from_secs(1), second_server)
                .await
                .expect("second server timeout")
                .expect("second server")
        );
        assert!(matches!(
            jobs.states.lock().await.get("replayed-request-id"),
            Some(JobState::Delivered(_))
        ));
        assert_eq!(
            fs::read_to_string(dir.join("count"))
                .expect("counter")
                .lines()
                .count(),
            1
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn renderer_script_wraps_top_level_return() {
        let bridge = build_bridge_script("test-instance").expect("bridge script");
        let script = build_renderer_script(&bridge);

        assert!(script.starts_with("(() => {"));
        assert!(script.contains("window.__REDPEN_CHATGPT_APP_RENDERER__"));
        assert!(script.ends_with("})();"));
    }

    #[test]
    fn host_app_executable_accepts_chatgpt_and_legacy_codex() {
        let dir = std::env::temp_dir().join(format!("redpen-host-app-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);

        let chatgpt = dir.join("ChatGPT.app");
        fs::create_dir_all(chatgpt.join("Contents/MacOS")).expect("chatgpt bundle");
        fs::create_dir_all(chatgpt.join("Contents/Resources")).expect("chatgpt resources");
        fs::write(chatgpt.join("Contents/MacOS/ChatGPT"), "").expect("chatgpt executable");
        fs::write(chatgpt.join("Contents/Resources/codex"), "").expect("bundled codex");
        assert_eq!(
            ensure_host_app(&chatgpt).expect("chatgpt executable"),
            chatgpt.join("Contents/MacOS/ChatGPT")
        );
        assert_eq!(
            bundled_codex_bin(&chatgpt),
            Some(chatgpt.join("Contents/Resources/codex"))
        );

        let codex = dir.join("Codex.app");
        fs::create_dir_all(codex.join("Contents/MacOS")).expect("codex bundle");
        fs::write(codex.join("Contents/MacOS/Codex"), "").expect("codex executable");
        assert_eq!(
            ensure_host_app(&codex).expect("codex executable"),
            codex.join("Contents/MacOS/Codex")
        );
        assert_eq!(bundled_codex_bin(&codex), None);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn bundled_coach_files_are_written_together() {
        let dir =
            std::env::temp_dir().join(format!("redpen-chatgpt-app-test-{}", std::process::id()));
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
