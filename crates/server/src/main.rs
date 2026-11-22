//! nautilus-mcp: the one MCP server a client registers.
//!
//! It serves three things through one stdio connection:
//!
//! - the **core** tools, unprefixed — in-process on Linux (Android, frames,
//!   crop/diff, OCR through tesseract), or on macOS the Swift server, run and
//!   supervised as an upstream so it too is restarted when it is rebuilt;
//! - every server in the config's `[servers.*]`, as `<server>__<tool>`;
//! - the config's `[wrapper.*]` shell commands, as tools.
//!
//! With no subcommand it serves, exactly as it always has, so an existing
//! `claude mcp add nautilus -- nautilus-mcp` keeps working. The subcommands
//! (`add`, `wrap`, `rm`, `ls`, `tools`, `call`, `auth`, `logout`) edit the
//! config and talk to servers from a terminal.

mod cli;
mod frames;
mod mcp;
mod proxy;
mod tools;

use std::cell::RefCell;
use std::fs::File;
use std::io::{BufRead, Write};
use std::os::fd::FromRawFd;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

use mcp::{Server, Tool};
use proxy::auth::Store;
use proxy::config;
use proxy::conn::Event;
use proxy::hub::{Core, Hub, CORE_NAME};
use proxy::upstream::{Dialer, Options, Upstream};
use tools::{Frames, ImageCropTool, ImageDiffTool, ImageOcrTool, Tesseract};

const USAGE: &str = "\
nautilus-mcp — one MCP server for Android control, macOS perception, and the
other MCP servers you develop.

Usage:
  nautilus-mcp [serve] [options]     speak MCP over stdio (the default)
  nautilus-mcp add [flags] <name> -- <command> [args...]
  nautilus-mcp add [flags] <name> <url>
  nautilus-mcp wrap [flags] <name> '<shell command>'
  nautilus-mcp rm <name>...
  nautilus-mcp ls [-v]
  nautilus-mcp tools [flags] [<name>...]
  nautilus-mcp call [flags] <name> <tool> [arguments...]
  nautilus-mcp auth [flags] <name>
  nautilus-mcp logout <name>
  nautilus-mcp help [<command>]

Serve options:
  --android <serial|auto|off>  Which Android device to bind (default: auto).
  --config <path>              Configuration file (TOML). Default:
                               $NAUTILUS_CONFIG, else
                               ~/.config/nautilus/config.toml if it exists.
  --core <path|off>            The core server. Default: nautilus-mcp-macos
                               next to this binary if present (the macOS
                               build), else the in-process portable tools.
  --voice <identifier>         Passed to the macOS core's `say`.
  --prototypes <dir>           Passed to the macOS core.
  --poll <duration>            Config and rebuild polling (default 1s; 0 off).
  --settle <duration>          Files must be still this long before a restart
                               (default 300ms).
  --start-timeout <duration>   For a server to start and list tools (30s).
  --list-tools                 Print the tool names and exit.
  --help                       Show this message.

Environment:
  ADB, TESSERACT               the adb and tesseract binaries";

fn log(text: &str) {
    eprintln!("nautilus-mcp: {text}");
}

/// **stdout is the transport.** Take a private duplicate of fd 1 for the
/// protocol, then point fd 1 at stderr, so a stray `println!` anywhere lands
/// harmlessly on stderr instead of corrupting the stream.
fn claim_transport() -> File {
    // SAFETY: plain fd syscalls on the process's own standard descriptors.
    unsafe {
        let duplicated = libc::dup(libc::STDOUT_FILENO);
        if duplicated < 0 {
            return File::from_raw_fd(libc::STDOUT_FILENO);
        }
        libc::dup2(libc::STDERR_FILENO, libc::STDOUT_FILENO);
        File::from_raw_fd(duplicated)
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("serve") => serve(&args[1..]),
        Some("help") => {
            match args.get(1) {
                Some(c) => println!("{}", cli::help(c).unwrap_or(USAGE)),
                None => println!("{USAGE}"),
            }
            0
        }
        Some(cmd) if cli::is_command(cmd) => cli::run(cmd, &args[1..]),
        _ => serve(&args),
    };
    std::process::exit(code);
}

struct ServeArgs {
    android: Option<String>,
    config: Option<String>,
    core: Option<String>,
    voice: Option<String>,
    prototypes: Option<String>,
    poll: Duration,
    settle: Duration,
    start_timeout: Duration,
    list_only: bool,
}

fn parse_serve(args: &[String]) -> Result<Option<ServeArgs>, String> {
    let mut a = ServeArgs {
        android: Some("auto".into()),
        config: None,
        core: None,
        voice: std::env::var("NAUTILUS_TTS_VOICE").ok(),
        prototypes: std::env::var("NAUTILUS_PROTOTYPES").ok(),
        poll: Duration::from_secs(1),
        settle: Duration::from_millis(300),
        start_timeout: Duration::from_secs(30),
        list_only: false,
    };
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let flag = arg.trim_start_matches('-');
        let mut value = || {
            it.next()
                .cloned()
                .ok_or_else(|| format!("{arg} needs a value"))
        };
        match flag {
            "help" | "h" => return Ok(None),
            "list-tools" => a.list_only = true,
            "android" => a.android = Some(value()?),
            "config" => a.config = Some(value()?),
            "core" => a.core = Some(value()?),
            "voice" => a.voice = Some(value()?),
            "prototypes" => a.prototypes = Some(value()?),
            "poll" => a.poll = config::parse_duration(&value()?)?,
            "settle" => a.settle = config::parse_duration(&value()?)?,
            "start-timeout" => a.start_timeout = config::parse_duration(&value()?)?,
            _ => return Err(format!("unknown option {arg}")),
        }
    }
    Ok(Some(a))
}

/// The Swift server, when this is the macOS install.
fn core_path(flag: Option<&str>) -> Option<PathBuf> {
    match flag {
        Some("off") => None,
        Some(p) => Some(config::expand_home(p)),
        None => {
            let sibling = std::env::current_exe()
                .ok()?
                .with_file_name("nautilus-mcp-macos");
            sibling.is_file().then_some(sibling)
        }
    }
}

fn serve(args: &[String]) -> i32 {
    let a = match parse_serve(args) {
        Ok(Some(a)) => a,
        Ok(None) => {
            println!("{USAGE}");
            return 0;
        }
        Err(e) => {
            log(&e);
            println!("{USAGE}");
            return 2;
        }
    };

    // Before stdout is claimed, so a bad --config can be reported plainly and
    // refuse to start: naming a path and silently getting defaults is the
    // failure that wastes an afternoon. A broken *default* file still starts,
    // with the error in nautilus_status, so the fix is picked up live.
    let (config_path, explicit) = config::resolve_path(a.config.as_deref());
    let (cfg, config_error) = match config::load(&config_path) {
        Ok(cfg) if explicit && !config_path.exists() => {
            let _ = cfg;
            log(&format!("{}: no such file", config_path.display()));
            return 2;
        }
        Ok(cfg) => (cfg, None),
        Err(e) if explicit => {
            log(&e);
            return 2;
        }
        Err(e) => (config::Config::default(), Some(e)),
    };

    let mut transport = claim_transport();
    let (tx, rx) = crossbeam_channel::unbounded::<Event>();

    let mut startup: Vec<String> = Vec::new();
    let mut note = |text: String| {
        log(&text);
        startup.push(text);
    };
    note(format!(
        "config {}: {} server(s), {} wrapper(s)",
        config_path.display(),
        cfg.servers.len(),
        cfg.wrapper.len()
    ));
    if let Some(e) = &config_error {
        note(format!(
            "config not loaded; serving no proxied servers until it is fixed: {e}"
        ));
    }

    let opts = Options {
        settle: a.settle,
        start_timeout: a.start_timeout,
        pass_stderr: true,
        events: Some(tx.clone()),
    };

    let core = match core_path(a.core.as_deref()) {
        Some(path) => {
            note(format!(
                "core: {} (supervised; restarted when rebuilt)",
                path.display()
            ));
            let mut core_args = Vec::new();
            if let Some(v) = &a.android {
                core_args.extend(["--android".to_string(), v.clone()]);
            }
            if explicit {
                core_args.extend(["--config".to_string(), config_path.display().to_string()]);
            }
            if let Some(v) = &a.voice {
                core_args.extend(["--voice".to_string(), v.clone()]);
            }
            if let Some(v) = &a.prototypes {
                core_args.extend(["--prototypes".to_string(), v.clone()]);
            }
            let dialer = Dialer::Stdio {
                command: path.display().to_string(),
                args: core_args,
                env: vec![],
            };
            Core::Remote(Box::new(Upstream::new(
                CORE_NAME,
                "",
                dialer,
                &[],
                opts.clone(),
            )))
        }
        None => Core::Local(local_tools(a.android.as_deref(), &mut note)),
    };

    let creds = Store::new(config::credentials_dir(&config_path));
    let mut hub = Hub::new(opts, creds, config_path, core, startup);
    if let Some(e) = config_error {
        hub.set_config_error(e);
    }
    hub.start_core();
    hub.apply(&cfg);

    let mut server = Server::new("nautilus-mcp", env!("CARGO_PKG_VERSION"));

    if a.list_only {
        for t in hub.list() {
            if let Some(n) = t.get("name").and_then(|n| n.as_str()) {
                let _ = writeln!(transport, "{n}");
            }
        }
        hub.close();
        return 0;
    }

    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            for line in std::io::stdin().lock().lines() {
                let Ok(line) = line else { break };
                if tx.send(Event::Line(line)).is_err() {
                    return;
                }
            }
            let _ = tx.send(Event::Eof);
        });
    }
    if !a.poll.is_zero() {
        let tx = tx.clone();
        let every = a.poll;
        std::thread::spawn(move || loop {
            std::thread::sleep(every);
            if tx.send(Event::Tick).is_err() {
                return;
            }
        });
    }
    drop(tx);

    let signature = |hub: &Hub| serde_json::to_string(&hub.list()).unwrap_or_default();
    let mut last = signature(&hub);
    log(&format!("ready on stdio with {} tool(s)", hub.list().len()));

    // Events taken off the channel while coalescing ticks, kept in order.
    let mut backlog: std::collections::VecDeque<Event> = std::collections::VecDeque::new();
    while let Some(event) = backlog.pop_front().or_else(|| rx.recv().ok()) {
        match event {
            Event::Line(line) => {
                if let Some(response) = server.handle(&line, &mut hub) {
                    if writeln!(transport, "{response}")
                        .and_then(|_| transport.flush())
                        .is_err()
                    {
                        break;
                    }
                }
            }
            Event::Tick => {
                // Ticks pile up behind a slow call or restart; one poll covers
                // them all. Anything else drained here is kept, in order —
                // dropping it would lose a request.
                while let Ok(next) = rx.try_recv() {
                    if !matches!(next, Event::Tick) {
                        backlog.push_back(next);
                    }
                }
                hub.poll();
            }
            Event::ToolsChanged {
                server: name,
                generation,
            } => hub.tools_changed(&name, generation),
            Event::Eof => break,
        }
        // Several events can report one change; the client hears it once.
        let now = signature(&hub);
        if now != last {
            last = now;
            if server.initialized {
                let _ = writeln!(transport, "{}", mcp::list_changed_line())
                    .and_then(|_| transport.flush());
            }
        }
    }
    hub.close();
    log("stdin closed, exiting");
    0
}

/// The in-process portable tools.
fn local_tools(android: Option<&str>, note: &mut dyn FnMut(String)) -> Vec<Box<dyn Tool>> {
    let frames: Frames = Rc::new(RefCell::new(frames::FrameStore::default()));
    let mut tools: Vec<Box<dyn Tool>> = vec![
        Box::new(ImageCropTool {
            frames: frames.clone(),
        }),
        Box::new(ImageDiffTool {
            frames: frames.clone(),
        }),
    ];

    let ocr = match Tesseract::detect() {
        Ok(t) => {
            note(format!(
                "OCR available through tesseract ({})",
                t.languages.join(", ")
            ));
            let t = Rc::new(t);
            tools.push(Box::new(ImageOcrTool {
                frames: frames.clone(),
                ocr: t.clone(),
            }));
            Some(t)
        }
        Err(why) => {
            note(format!("no image_ocr / android_read_text: {why}"));
            None
        }
    };

    match android {
        None | Some("off") => note("Android tools disabled (--android off)".into()),
        Some(spec) => {
            let serial = (spec != "auto").then(|| spec.to_string());
            match tools::android_tools(serial, &frames, ocr) {
                Ok(list) => {
                    note(format!("bound Android device, {} tool(s)", list.len()));
                    tools.extend(list);
                }
                Err(why) => note(format!("no Android tools: {why}")),
            }
        }
    }
    tools
}
