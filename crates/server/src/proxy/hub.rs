//! The hub: everything `tools/list` shows and `tools/call` reaches.
//!
//! | | names | from |
//! |---|---|---|
//! | core | unprefixed (`android_tap`, `macos_capture_window`) | in-process on Linux; the Swift server, supervised, on macOS |
//! | proxied | `<server>__<tool>` | `[servers.*]` in the config |
//! | wrappers | the wrapper's name | `[wrapper.*]` |
//! | built-ins | `nautilus_*` | here |
//!
//! Everything runs on the main thread, one event at a time — requests are
//! serialized as they always were here. Background work is only a ticker and
//! the upstreams' reader threads; both wake the main loop through a channel.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use super::auth::Store;
use super::config::{self, Config, Server, Wrapper, RESERVED_PREFIX, TOOL_SEPARATOR};
use super::search;
use super::upstream::{error_result, tool_name, Dialer, Options, Upstream};
use super::wrapper;
use crate::mcp::{Args, Tool, ToolOutput};

pub const STATUS: &str = "nautilus_status";
pub const RESTART: &str = "nautilus_restart";
pub const SEARCH: &str = "nautilus_search_tools";
pub const CALL: &str = "nautilus_call_tool";
pub const REFRESH: &str = "nautilus_refresh";
/// The supervised Swift server's name in status and `nautilus_restart`. It
/// starts with the reserved prefix, so no configured server can take it.
pub const CORE_NAME: &str = "nautilus-macos";

const DEFAULT_MAX_RESULTS: u64 = 5;

/// What the macOS build has that the in-process core does not.
const MACOS_ONLY: [(&str, &str); 9] = [
    (
        "image_ocr / android_read_text",
        "Vision OCR; on Linux, look at an image_crop instead",
    ),
    (
        "macos_list_windows / macos_capture_window / macos_read_text",
        "ScreenCaptureKit",
    ),
    ("macos_detect_objects / image_regions", "Vision"),
    (
        "visual_learn / visual_find / visual_list / android_look_for",
        "Vision feature prints",
    ),
    (
        "android_tap_region",
        "image_regions ids; android_tap takes the same point",
    ),
    ("browser_observe", "macOS Accessibility"),
    ("say", "AVSpeechSynthesizer"),
    ("ask_local_model", "Apple's on-device model"),
    ("macos_permissions", "TCC grants"),
];

/// Builds the in-process tools from what the machine offers right now, with a
/// note for each thing found or missing.
pub type Builder = Box<dyn Fn() -> (Vec<Box<dyn Tool>>, Vec<String>)>;

pub enum Core {
    /// The portable tools, in-process. `rebuild` is how `nautilus_refresh`
    /// notices a device plugged in after startup.
    Local {
        tools: Vec<Box<dyn Tool>>,
        notes: Vec<String>,
        rebuild: Option<Builder>,
    },
    /// The Swift server, as an upstream whose tools are not prefixed.
    Remote(Box<Upstream>),
}

impl Core {
    /// Build now, and keep the builder for later refreshes.
    pub fn local(build: Builder) -> Self {
        let (tools, notes) = build();
        Core::Local {
            tools,
            notes,
            rebuild: Some(build),
        }
    }

    /// A fixed set, for tests.
    #[cfg(test)]
    pub fn fixed(tools: Vec<Box<dyn Tool>>) -> Self {
        Core::Local {
            tools,
            notes: vec![],
            rebuild: None,
        }
    }
}

struct Backend {
    server: Server,
    /// `None` when the server could not even be set up; see `err`.
    upstream: Option<Upstream>,
    err: Option<String>,
}

pub struct Hub {
    opts: Options,
    creds: Store,
    config_path: PathBuf,
    config_stamp: Option<(u64, SystemTime)>,
    config_error: Option<String>,
    backends: BTreeMap<String, Backend>,
    wrappers: BTreeMap<String, Wrapper>,
    core: Core,
    startup: Vec<String>,
}

/// A request that was never valid: unknown tool. Becomes `-32602`.
pub struct UnknownTool(pub String);

fn stamp(path: &std::path::Path) -> Option<(u64, SystemTime)> {
    std::fs::metadata(path)
        .ok()
        .map(|m| (m.len(), m.modified().unwrap_or(UNIX_EPOCH)))
}

fn log(text: &str) {
    eprintln!("nautilus-mcp: {text}");
}

impl Hub {
    pub fn new(
        opts: Options,
        creds: Store,
        config_path: PathBuf,
        core: Core,
        startup: Vec<String>,
    ) -> Self {
        Self {
            opts,
            creds,
            config_stamp: stamp(&config_path),
            config_path,
            config_error: None,
            backends: BTreeMap::new(),
            wrappers: BTreeMap::new(),
            core,
            startup,
        }
    }

    pub fn set_config_error(&mut self, e: String) {
        self.config_error = Some(e);
    }

    /// Start the core, if it is a server.
    pub fn start_core(&mut self) {
        if let Core::Remote(up) = &mut self.core {
            match up.start() {
                Ok(()) => self.startup.push(format!(
                    "{CORE_NAME}: started, {} tool(s)",
                    up.tools().len()
                )),
                Err(e) => {
                    log(&format!("{CORE_NAME} failed to start: {e}"));
                    self.startup
                        .push(format!("{CORE_NAME}: failed to start (see {STATUS})"));
                }
            }
        }
    }

    /// Make the running backends match `cfg`. Removed or changed servers stop;
    /// new or changed ones start, in parallel.
    pub fn apply(&mut self, cfg: &Config) {
        self.config_error = None;
        self.wrappers = cfg.wrapper.clone();

        let gone: Vec<String> = self
            .backends
            .iter()
            .filter(|(name, b)| cfg.servers.get(*name) != Some(&b.server))
            .map(|(name, _)| name.clone())
            .collect();
        for name in gone {
            log(&format!("stopping {name}"));
            if let Some(mut b) = self.backends.remove(&name) {
                if let Some(up) = b.upstream.as_mut() {
                    up.close();
                }
            }
        }

        let mut fresh = Vec::new();
        for (name, srv) in &cfg.servers {
            if self.backends.contains_key(name) {
                continue;
            }
            let backend = match Dialer::for_server(name, srv, Some(self.creds.clone())) {
                Ok(d) => Backend {
                    server: srv.clone(),
                    upstream: Some(Upstream::new(
                        name,
                        &format!("{name}{TOOL_SEPARATOR}"),
                        d,
                        &srv.watch,
                        self.opts.clone(),
                    )),
                    err: None,
                },
                Err(e) => Backend {
                    server: srv.clone(),
                    upstream: None,
                    err: Some(e),
                },
            };
            self.backends.insert(name.clone(), backend);
            fresh.push(name.clone());
        }

        // Parallel, because a slow server must not hold up the others.
        let mut starting: Vec<&mut Upstream> = self
            .backends
            .iter_mut()
            .filter(|(n, _)| fresh.contains(n))
            .filter_map(|(_, b)| b.upstream.as_mut())
            .collect();
        std::thread::scope(|s| {
            for up in starting.iter_mut() {
                s.spawn(move || {
                    if let Err(e) = up.start() {
                        log(&format!("{} failed to start: {}", up.name, first_line(&e)));
                    }
                });
            }
        });
    }

    /// Called on every tick: reload a changed config, restart rebuilt servers.
    pub fn poll(&mut self) {
        let now = stamp(&self.config_path);
        if now != self.config_stamp {
            self.config_stamp = now;
            match config::load(&self.config_path) {
                Ok(cfg) => {
                    log("config changed, reloading");
                    self.apply(&cfg);
                }
                Err(e) => {
                    log(&format!(
                        "config reload failed; keeping current servers: {e}"
                    ));
                    self.config_error = Some(e);
                }
            }
        }
        for up in self.upstreams_mut() {
            if up.changed() {
                log(&format!("{} changed on disk, restarting", up.name));
                if let Err(e) = up.restart(false) {
                    log(&format!("{} restart failed: {}", up.name, first_line(&e)));
                }
            }
        }
    }

    /// A server announced `tools/list_changed`.
    pub fn tools_changed(&mut self, server: &str, generation: u64) {
        if let Some(up) = self.upstreams_mut().into_iter().find(|u| u.name == server) {
            if let Err(e) = up.relist(Some(generation)) {
                log(&format!(
                    "re-listing {server} after list_changed failed: {e}"
                ));
            }
        }
    }

    fn upstreams_mut(&mut self) -> Vec<&mut Upstream> {
        let mut out: Vec<&mut Upstream> = self
            .backends
            .values_mut()
            .filter_map(|b| b.upstream.as_mut())
            .collect();
        if let Core::Remote(up) = &mut self.core {
            out.push(up);
        }
        out
    }

    pub fn close(&mut self) {
        for up in self.upstreams_mut() {
            up.close();
        }
    }

    fn core_tools(&self) -> Vec<Value> {
        match &self.core {
            Core::Local { tools, .. } => tools
                .iter()
                .map(|t| json!({ "name": t.name(), "description": t.description(), "inputSchema": t.input_schema() }))
                .collect(),
            Core::Remote(up) => up.tools().to_vec(),
        }
    }

    fn proxied_tools(&self) -> Vec<Value> {
        let mut out = Vec::new();
        for (name, b) in &self.backends {
            if let Some(up) = &b.upstream {
                for t in up.tools() {
                    let mut t = t.clone();
                    if let Some(n) = tool_name(&t).map(String::from) {
                        t["name"] = format!("{name}{TOOL_SEPARATOR}{n}").into();
                        out.push(t);
                    }
                }
            }
        }
        out
    }

    /// Wrappers whose name a core tool already has are left out (and said so
    /// in the status): the core tool is what that name has always meant.
    fn wrapper_tools(&self, core: &[Value]) -> Vec<Value> {
        self.wrappers
            .iter()
            .filter(|(n, _)| !core.iter().any(|t| tool_name(t) == Some(n.as_str())))
            .map(|(n, w)| wrapper::definition(n, w))
            .collect()
    }

    pub fn list(&self) -> Vec<Value> {
        let core = self.core_tools();
        let mut out = core.clone();
        out.extend(self.proxied_tools());
        out.extend(self.wrapper_tools(&core));
        out.extend(self.builtin_definitions());
        out
    }

    pub fn call(&mut self, name: &str, args: &Args) -> Result<Value, UnknownTool> {
        match name {
            STATUS => return Ok(text_result(self.status_text())),
            REFRESH => return Ok(self.refresh_core()),
            RESTART => return Ok(self.restart_tool(args)),
            SEARCH => return Ok(self.search_tool(args)),
            CALL => {
                let Some(inner) = args.get("name").and_then(Value::as_str) else {
                    return Ok(error_result("missing string `name`"));
                };
                if inner.starts_with(RESERVED_PREFIX) {
                    return Ok(error_result(format!(
                        "nautilus-mcp: call {inner} directly; {CALL} is for proxied, wrapper and core tools"
                    )));
                }
                let inner_args = match args.get("arguments") {
                    Some(Value::Object(o)) => o.clone(),
                    _ => Args::new(),
                };
                return Ok(self
                    .route(inner, &inner_args)
                    .unwrap_or_else(|UnknownTool(m)| error_result(format!("nautilus-mcp: {m}"))));
            }
            _ => {}
        }
        self.route(name, args)
    }

    fn route(&mut self, name: &str, args: &Args) -> Result<Value, UnknownTool> {
        if let Some((server, tool)) = name.split_once(TOOL_SEPARATOR) {
            let names: Vec<String> = self.backends.keys().cloned().collect();
            let Some(b) = self.backends.get_mut(server) else {
                return Err(UnknownTool(format!(
                    "Unknown tool: {name}. There is no server named {server:?}; servers: {}",
                    list_or_none(&names)
                )));
            };
            return Ok(match b.upstream.as_mut() {
                Some(up) => up.call(tool, Value::Object(args.clone())),
                None => error_result(format_backend(server, b)),
            });
        }

        match &mut self.core {
            Core::Local { tools, .. } => {
                if let Some(t) = tools.iter().find(|t| t.name() == name) {
                    return Ok(match t.call(args) {
                        Ok(out) => output_value(out),
                        Err(f) => error_result(format!("{name} failed: {}", f.message)),
                    });
                }
            }
            Core::Remote(up) => {
                if up.tools().iter().any(|t| tool_name(t) == Some(name)) {
                    return Ok(up.call(name, Value::Object(args.clone())));
                }
            }
        }

        if let Some(w) = self.wrappers.get(name) {
            return Ok(wrapper::run(w).tool_result());
        }

        let available: Vec<String> = self
            .list()
            .iter()
            .filter_map(tool_name)
            .map(String::from)
            .collect();
        Err(UnknownTool(format!(
            "Unknown tool: {name}. Available: {}",
            available.join(", ")
        )))
    }

    fn server_names(&self) -> Vec<String> {
        self.backends.keys().cloned().collect()
    }

    fn builtin_definitions(&self) -> Vec<Value> {
        let servers = list_or_none(&self.server_names());
        vec![
            json!({
                "name": STATUS,
                "description": "Explain what this server can do on this machine and why anything is \
                    missing: the core tools (and, on Linux, which macOS tools do not exist here), \
                    every proxied MCP server with whether it is running, its tools and its last \
                    error (a failed build's stderr, an authorization problem), the wrapper tools, \
                    and any config error. Call this whenever a tool you expected is missing or a \
                    proxied tool fails.",
                "inputSchema": { "type": "object", "properties": {} },
                "annotations": { "readOnlyHint": true, "destructiveHint": false,
                                 "idempotentHint": true, "openWorldHint": false },
            }),
            json!({
                "name": REFRESH,
                "description": format!("Look again at what this machine offers and update the tool \
                    list: an Android device plugged in (or unplugged) since nautilus-mcp started. The device is otherwise only detected at startup. \
                    On macOS this restarts the core server. Frames captured before become stale. \
                    Reports which tools were added or removed; {STATUS} explains anything still missing."),
                "inputSchema": { "type": "object", "properties": {} },
                "annotations": { "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            }),
            json!({
                "name": RESTART,
                "description": format!("Restart one MCP server behind nautilus-mcp (or reconnect \
                    to a remote one) and report its status. Rebuilds are picked up automatically; \
                    use this when the server depends on files that are not watched. Servers: {servers}."),
                "inputSchema": { "type": "object",
                    "properties": { "server": { "type": "string", "description": format!("Server name, as in {STATUS}") } },
                    "required": ["server"] },
                "annotations": { "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            }),
            json!({
                "name": SEARCH,
                "description": format!("Search the tools behind nautilus-mcp as they are now \
                    (servers: {servers}). Tools change when a server is rebuilt or the config \
                    changes, so the client's own tool search may not see them or may hold \
                    outdated schemas. Returns full definitions. Proxied tools are named \
                    \"<server>__<tool>\".\n\nQuery forms:\n\
                    - \"select:name1,name2\": fetch these exact tools by name\n\
                    - \"keyword another\": keyword search, up to max_results best matches\n\
                    - \"+word keyword\": require \"word\" in the tool name, rank by the rest \
                    (e.g. \"+godev__ search\" searches only the server godev)\n\
                    - \"\": list all tools\n\n\
                    Call a found tool directly if you have it, otherwise via {CALL}."),
                "inputSchema": { "type": "object", "properties": {
                    "query": { "type": "string", "description": "Search query; see the description for the forms." },
                    "max_results": { "type": "number", "default": DEFAULT_MAX_RESULTS,
                                     "description": "Maximum keyword results; 0 for no limit." },
                }, "required": ["query"] },
                "annotations": { "readOnlyHint": true, "destructiveHint": false,
                                 "idempotentHint": true, "openWorldHint": false },
            }),
            json!({
                "name": CALL,
                "description": format!("Call a tool behind nautilus-mcp by its full name — \
                    \"<server>__<tool>\" for a proxied server (servers: {servers}), or a wrapper \
                    or core tool's plain name. Use it for tools missing from your tool list or \
                    whose schema there is outdated. Find tools with {SEARCH}."),
                "inputSchema": { "type": "object", "properties": {
                    "name": { "type": "string", "description": "Tool name, e.g. \"<server>__<tool>\"" },
                    "arguments": { "type": "object", "description": "Arguments matching the tool's input schema" },
                }, "required": ["name"] },
            }),
        ]
    }

    pub fn status_text(&self) -> String {
        let mut s = String::new();
        s.push_str(&format!(
            "nautilus-mcp {} on {}/{}\n\n",
            env!("CARGO_PKG_VERSION"),
            std::env::consts::OS,
            std::env::consts::ARCH
        ));
        match &self.core {
            Core::Local { tools, notes, .. } => {
                let names: Vec<String> = tools.iter().map(|t| t.name()).collect();
                s.push_str(&format!("[core] in-process\ntools: {}\n", names.join(", ")));
                for n in notes {
                    s.push_str(&format!("  {n}\n"));
                }
                s.push_str(&format!("  (plugged a device in since? call {REFRESH})\n"));
                s.push_str("not in this build (macOS only):\n");
                for (t, why) in MACOS_ONLY {
                    s.push_str(&format!("  {t} — needs {why}\n"));
                }
            }
            Core::Remote(up) => s.push_str(&format_upstream(CORE_NAME, up)),
        }
        if !self.startup.is_empty() {
            s.push_str("startup:\n");
            for n in &self.startup {
                s.push_str(&format!("  {n}\n"));
            }
        }
        s.push('\n');

        s.push_str(&format!("config: {}\n", self.config_path.display()));
        if let Some(e) = &self.config_error {
            s.push_str(&format!(
                "config error (the servers below are from the last valid config): {e}\n"
            ));
        }
        s.push('\n');
        if self.backends.is_empty() && self.wrappers.is_empty() {
            s.push_str(
                "No proxied servers or wrapper tools are configured. The user can add one with \
                 `nautilus-mcp add <name> -- <command> [args...]`, `nautilus-mcp add <name> <url>` \
                 or `nautilus-mcp wrap <name> '<shell command>'`.\n",
            );
        }
        for (name, b) in &self.backends {
            s.push_str(&format_backend(name, b));
            s.push('\n');
        }
        let core = self.core_tools();
        for (name, w) in &self.wrappers {
            let dir = if w.dir.is_empty() {
                "(nautilus-mcp's working directory)"
            } else {
                &w.dir
            };
            s.push_str(&format!(
                "[{name}] wrapper tool: {}\ndir: {dir}\n",
                w.command
            ));
            if core.iter().any(|t| tool_name(t) == Some(name.as_str())) {
                s.push_str("not listed: a core tool already has this name; rename the wrapper\n");
            }
            s.push('\n');
        }
        s
    }

    /// Look again at what the machine offers and rebuild the core tools.
    ///
    /// No notification is sent from here, and none needs to be: the main loop
    /// compares the whole tool list after *every* event — this call included —
    /// and sends `tools/list_changed` when it differs. That one place covers
    /// rebuilds, config reloads and this alike, and sends it once.
    fn refresh_core(&mut self) -> Value {
        match &mut self.core {
            Core::Local {
                tools,
                notes,
                rebuild: Some(build),
            } => {
                let before: Vec<String> = tools.iter().map(|t| t.name()).collect();
                let (fresh, fresh_notes) = build();
                let after: Vec<String> = fresh.iter().map(|t| t.name()).collect();
                *tools = fresh;
                *notes = fresh_notes;

                let added: Vec<&String> = after.iter().filter(|n| !before.contains(n)).collect();
                let removed: Vec<&String> = before.iter().filter(|n| !after.contains(n)).collect();
                let mut s = String::new();
                match (added.is_empty(), removed.is_empty()) {
                    (true, true) => s.push_str("No change in the core tools.\n"),
                    _ => {
                        if !added.is_empty() {
                            s.push_str(&format!("added: {}\n", join(&added)));
                        }
                        if !removed.is_empty() {
                            s.push_str(&format!("removed: {}\n", join(&removed)));
                        }
                    }
                }
                for n in notes.iter() {
                    s.push_str(&format!("{n}\n"));
                }
                s.push_str(
                    "Frames captured before this refresh are stale; observe again before reading one.\n",
                );
                text_result(s)
            }
            Core::Local { rebuild: None, .. } => text_result("This core has nothing to refresh."),
            Core::Remote(up) => {
                // The Swift server binds its device at startup, so looking
                // again means starting it again.
                let ok = up.restart(true).is_ok();
                let text = format!("Restarted the core.\n{}", format_upstream(CORE_NAME, up));
                if ok {
                    text_result(text)
                } else {
                    error_result(text)
                }
            }
        }
    }

    fn restart_tool(&mut self, args: &Args) -> Value {
        let name = args.get("server").and_then(Value::as_str).unwrap_or("");
        if name == CORE_NAME {
            if let Core::Remote(up) = &mut self.core {
                let ok = up.restart(true).is_ok();
                let text = format_upstream(CORE_NAME, up);
                return if ok {
                    text_result(text)
                } else {
                    error_result(text)
                };
            }
        }
        let names = self.server_names();
        let Some(b) = self.backends.get_mut(name) else {
            return error_result(format!(
                "nautilus-mcp: no server named {name:?}. Servers: {}",
                list_or_none(&names)
            ));
        };
        let ok = match b.upstream.as_mut() {
            Some(up) => up.restart(true).is_ok(),
            None => false,
        };
        let text = format_backend(name, b);
        if ok {
            text_result(text)
        } else {
            error_result(text)
        }
    }

    fn search_tool(&mut self, args: &Args) -> Value {
        let query = args.get("query").and_then(Value::as_str).unwrap_or("");
        let max = args
            .get("max_results")
            .and_then(Value::as_f64)
            .map(|v| v.max(0.0) as usize)
            .unwrap_or(DEFAULT_MAX_RESULTS as usize);

        // Bring every server up to its current build first: this is the tool
        // for seeing what a rebuild changed.
        let mut warnings = Vec::new();
        for (name, b) in self.backends.iter_mut() {
            match b.upstream.as_mut() {
                None => warnings.push(format!(
                    "{name}: not usable: {}",
                    b.err.as_deref().unwrap_or("?")
                )),
                Some(up) => {
                    if let Err(e) = up.refresh() {
                        warnings.push(format!(
                            "{name}: not running (showing its last known tools, if any): {}",
                            first_line(&e)
                        ));
                    }
                }
            }
        }
        if let Core::Remote(up) = &mut self.core {
            if let Err(e) = up.refresh() {
                warnings.push(format!("{CORE_NAME}: not running: {}", first_line(&e)));
            }
        }

        let core = self.core_tools();
        let mut tools = core.clone();
        tools.extend(self.proxied_tools());
        tools.extend(self.wrapper_tools(&core));
        let res = search::search(&tools, query, max);

        let mut s = String::new();
        for w in &warnings {
            s.push_str(&format!("warning: {w}\n"));
        }
        if !warnings.is_empty() {
            s.push_str(&format!("(see {STATUS} for details)\n\n"));
        }
        s.push_str(&format!(
            "{} of {} matching tools ({} tools total)",
            res.tools.len(),
            res.total,
            tools.len()
        ));
        if !res.missing.is_empty() {
            s.push_str(&format!("; not found: {}", res.missing.join(", ")));
        }
        s.push('\n');
        if res.tools.is_empty() {
            let names: Vec<&str> = tools.iter().filter_map(tool_name).collect();
            s.push_str(&format!("available tools: {}\n", names.join(", ")));
            return text_result(s);
        }
        s.push_str("<functions>\n");
        for t in &res.tools {
            let mut def = json!({ "name": t["name"], "parameters": t.get("inputSchema").cloned().unwrap_or(json!({})) });
            if let Some(d) = t
                .get("description")
                .and_then(Value::as_str)
                .filter(|d| !d.is_empty())
            {
                def["description"] = d.into();
            }
            s.push_str(&format!("<function>{def}</function>\n"));
        }
        s.push_str("</functions>\n");
        s.push_str(&format!(
            "\nIf a tool is not in your tool list (or its schema there differs), call it with \
             {CALL} {{\"name\": ..., \"arguments\": {{...}}}}.\n"
        ));
        text_result(s)
    }
}

fn join(names: &[&String]) -> String {
    names
        .iter()
        .map(|s| s.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

fn list_or_none(names: &[String]) -> String {
    if names.is_empty() {
        "(none configured yet)".into()
    } else {
        names.join(", ")
    }
}

fn first_line(s: &str) -> &str {
    s.lines().next().unwrap_or("")
}

pub fn text_result(text: impl Into<String>) -> Value {
    json!({ "content": [{ "type": "text", "text": text.into() }], "isError": false })
}

pub fn output_value(out: ToolOutput) -> Value {
    let mut content = Vec::new();
    if !out.text.is_empty() {
        content.push(json!({ "type": "text", "text": out.text }));
    }
    for i in out.images {
        content.push(json!({ "type": "image", "data": i.base64, "mimeType": i.mime_type }));
    }
    json!({ "content": content, "isError": false })
}

fn format_backend(name: &str, b: &Backend) -> String {
    match &b.upstream {
        Some(up) => format_upstream(name, up),
        None => format!(
            "[{name}] {}\nstatus: not usable: {}\n",
            b.server.target(),
            b.err.as_deref().unwrap_or("?")
        ),
    }
}

fn format_upstream(name: &str, up: &Upstream) -> String {
    let st = up.status();
    let mut s = format!("[{name}] {}\n", st.target);
    if st.running {
        let when = st.started.map(rfc3339).unwrap_or_default();
        s.push_str(&format!(
            "status: running (generation {}, started {when})\n",
            st.generation
        ));
    } else {
        s.push_str("status: not running\n");
    }
    let tools: Vec<String> = st
        .tools
        .iter()
        .map(|t| format!("{}{t}", up.prefix))
        .collect();
    s.push_str(&format!("tools: {}\n", tools.join(", ")));
    if let Some(e) = &st.last_error {
        s.push_str(&format!("error: {e}\n"));
    } else if !st.running && !st.stderr.trim().is_empty() {
        s.push_str(&format!("stderr:\n{}\n", st.stderr.trim_end()));
    }
    s
}

/// UTC, to the second. No date library for one timestamp.
pub fn rfc3339(t: SystemTime) -> String {
    let secs = t
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_secs() as i64;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps_are_utc_rfc3339() {
        assert_eq!(rfc3339(UNIX_EPOCH), "1970-01-01T00:00:00Z");
        assert_eq!(
            rfc3339(UNIX_EPOCH + Duration::from_secs(1_795_000_000)),
            "2026-11-18T11:06:40Z"
        );
    }

    fn hub_with(wrappers: &[(&str, &str)]) -> Hub {
        struct Fake;
        impl Tool for Fake {
            fn name(&self) -> String {
                "image_crop".into()
            }
            fn description(&self) -> String {
                "crop".into()
            }
            fn input_schema(&self) -> Value {
                json!({"type": "object"})
            }
            fn call(&self, _: &Args) -> Result<ToolOutput, crate::mcp::ToolFailure> {
                Ok(ToolOutput::text("cropped"))
            }
        }
        let mut hub = Hub::new(
            Options {
                settle: Duration::ZERO,
                start_timeout: Duration::from_secs(5),
                pass_stderr: false,
                events: None,
            },
            Store::new(std::env::temp_dir()),
            PathBuf::from("/nonexistent/config.toml"),
            Core::fixed(vec![Box::new(Fake)]),
            vec![],
        );
        let mut cfg = Config::default();
        for (n, c) in wrappers {
            cfg.wrapper.insert(
                n.to_string(),
                Wrapper {
                    command: c.to_string(),
                    ..Default::default()
                },
            );
        }
        hub.apply(&cfg);
        hub
    }

    #[test]
    fn a_wrapper_cannot_shadow_a_core_tool() {
        let mut hub = hub_with(&[("image_crop", "echo shadow"), ("hello", "echo hi")]);
        let names: Vec<String> = hub
            .list()
            .iter()
            .filter_map(tool_name)
            .map(String::from)
            .collect();
        assert_eq!(names.iter().filter(|n| *n == "image_crop").count(), 1);
        assert!(names.contains(&"hello".to_string()));
        let r = hub.call("image_crop", &Args::new()).ok().unwrap();
        assert_eq!(r["content"][0]["text"], "cropped");
        let r = hub.call("hello", &Args::new()).ok().unwrap();
        assert_eq!(r["structuredContent"]["stdout"], "hi\n");
        assert!(hub
            .status_text()
            .contains("not listed: a core tool already has this name"));
    }

    #[test]
    fn unknown_names_are_protocol_errors_but_call_tool_reports_them() {
        let mut hub = hub_with(&[]);
        assert!(hub.call("nope", &Args::new()).is_err());
        let err = hub.call("ghost__tool", &Args::new()).err().unwrap();
        assert!(err.0.contains("no server named \"ghost\""), "{}", err.0);
        let mut args = Args::new();
        args.insert("name".into(), "ghost__tool".into());
        let r = hub.call(CALL, &args).ok().unwrap();
        assert_eq!(r["isError"], true);
        args.insert("name".into(), STATUS.into());
        assert_eq!(hub.call(CALL, &args).ok().unwrap()["isError"], true);
    }

    #[test]
    fn refresh_picks_up_a_device_plugged_in_later() {
        struct Named(&'static str);
        impl Tool for Named {
            fn name(&self) -> String {
                self.0.into()
            }
            fn description(&self) -> String {
                String::new()
            }
            fn input_schema(&self) -> Value {
                json!({"type": "object"})
            }
            fn call(&self, _: &Args) -> Result<ToolOutput, crate::mcp::ToolFailure> {
                Ok(ToolOutput::text("ok"))
            }
        }
        let plugged = std::rc::Rc::new(std::cell::Cell::new(false));
        let p = plugged.clone();
        let core = Core::local(Box::new(move || {
            let mut tools: Vec<Box<dyn Tool>> = vec![Box::new(Named("image_crop"))];
            if p.get() {
                tools.push(Box::new(Named("android_tap")));
                (tools, vec!["bound Android device".into()])
            } else {
                (tools, vec!["no Android tools: no device attached".into()])
            }
        }));
        let mut hub = Hub::new(
            Options {
                settle: Duration::ZERO,
                start_timeout: Duration::from_secs(5),
                pass_stderr: false,
                events: None,
            },
            Store::new(std::env::temp_dir()),
            PathBuf::from("/nonexistent/config.toml"),
            core,
            vec![],
        );
        let names = |h: &Hub| -> Vec<String> {
            h.list()
                .iter()
                .filter_map(tool_name)
                .map(String::from)
                .collect()
        };
        assert!(!names(&hub).contains(&"android_tap".to_string()));
        assert!(hub.status_text().contains("no device attached"));

        plugged.set(true);
        let r = hub.call(REFRESH, &Args::new()).ok().unwrap();
        let text = r["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("added: android_tap"), "{text}");
        assert!(names(&hub).contains(&"android_tap".to_string()));
        assert!(hub.status_text().contains("bound Android device"));
        assert_eq!(
            hub.call("android_tap", &Args::new()).ok().unwrap()["isError"],
            false
        );

        plugged.set(false);
        let r = hub.call(REFRESH, &Args::new()).ok().unwrap();
        assert!(r["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("removed: android_tap"));
        assert!(hub.call("android_tap", &Args::new()).is_err());

        let r = hub.call(REFRESH, &Args::new()).ok().unwrap();
        assert!(r["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("No change"));
    }

    #[test]
    fn search_covers_core_and_wrappers() {
        let mut hub = hub_with(&[("lint", "golangci-lint run")]);
        let mut args = Args::new();
        args.insert("query".into(), "select:lint,image_crop,nothing".into());
        let r = hub.call(SEARCH, &args).ok().unwrap();
        let text = r["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("2 of 2 matching tools"), "{text}");
        assert!(text.contains("not found: nothing"), "{text}");
        assert!(text.contains("<function>{"), "{text}");
    }
}
