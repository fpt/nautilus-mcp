//! adb-backed control of a single Android device.
//!
//! This is the transport half of the Android GUI-automation primitives: it
//! knows how to run `adb`, where the screen currently is, and how to turn a
//! normalized coordinate into a pixel one. It knows nothing about any game.
//!
//! # Why normalized coordinates
//!
//! Every model-facing entry point takes `0.0..=1.0`, not pixels. A skill
//! recorded as `tap(0.91, 0.54)` survives a different device, a different
//! panel, and a resolution change; `tap(1213, 404)` does not.
//!
//! # Why rotation is read, never assumed
//!
//! `wm size` reports the *panel*, not the display. On a landscape handheld
//! (Retroid Pocket 3+, rotation 1) it answers `752x1336` while the framebuffer,
//! and every coordinate `input tap` accepts, is `1336x752`. Trusting `wm size`
//! transposes every tap. [`Geometry`] is therefore read from
//! `dumpsys window displays`' `cur=` field, which is already rotation-applied,
//! and `wm size` is only a fallback — with the rotation swap applied by hand.
//!
//! Verified on a Retroid Pocket 3+ (Android 11, API 30): the screenshot is
//! 1336x752 and a tap at the Clock icon's screenshot pixel opened the Clock.

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crossbeam::channel;
use parking_lot::Mutex;

use crate::NautilusError;

/// How long any single `adb` invocation may take before it is killed. A wedged
/// adb must fail the tool call, not hang the whole turn.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(20);

/// Geometry is re-read this often. Rotation can change at any time (a game
/// going landscape), so the cache is deliberately short — an 82ms `dumpsys`
/// against a ~654ms `input` call is not the cost worth optimizing.
const GEOMETRY_TTL: Duration = Duration::from_secs(2);

/// The display as it is *right now*, with rotation already applied.
///
/// `width`/`height` are in the same space as both the screenshot and the
/// coordinates `input tap` accepts — the two agree, which is what makes
/// "tap what you see in the screenshot" work.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Geometry {
    pub width: u32,
    pub height: u32,
    /// Surface rotation: 0 = portrait, 1 = 90°, 2 = 180°, 3 = 270°.
    pub rotation: u32,
}

/// A point in device pixels, in the same space as [`Geometry`].
pub type Pixel = (i64, i64);

/// One attached device, as `adb devices -l` reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceInfo {
    pub serial: String,
    /// `device`, `unauthorized`, `offline`, …
    pub state: String,
    pub model: Option<String>,
}

/// A handle to one Android device over `adb`.
pub struct Device {
    adb: String,
    serial: Option<String>,
    timeout: Duration,
    geometry: Mutex<Option<(Geometry, Instant)>>,
}

impl Device {
    /// Bind to a device. `serial` of `None` lets adb pick, which is only
    /// unambiguous when exactly one device is attached — [`Device::resolve`]
    /// is the better entry point.
    pub fn new(serial: Option<String>) -> Self {
        Self {
            adb: std::env::var("ADB").unwrap_or_else(|_| "adb".to_string()),
            serial,
            timeout: DEFAULT_TIMEOUT,
            geometry: Mutex::new(None),
        }
    }

    /// Pick a device, failing with an explanation rather than a silent
    /// mis-target.
    ///
    /// `spec` is a serial, or `"auto"`/`"1"`/`""` to take the only attached
    /// device. Attaching two devices with `auto` is an error: guessing which
    /// phone to drive is not a decision this layer should make.
    pub fn resolve(spec: &str) -> Result<Self, NautilusError> {
        let spec = spec.trim();
        let auto = spec.is_empty() || spec.eq_ignore_ascii_case("auto") || spec == "1";
        if !auto {
            return Ok(Self::new(Some(spec.to_string())));
        }

        let probe = Self::new(None);
        let listed = probe.list_devices()?;
        let ready: Vec<&DeviceInfo> = listed.iter().filter(|d| d.state == "device").collect();

        match ready.as_slice() {
            [] if listed.is_empty() => Err(NautilusError::ConfigError(
                "no Android device attached (`adb devices` is empty). Connect one over USB and \
                 enable USB debugging."
                    .to_string(),
            )),
            // Attached but not usable: almost always the on-device
            // "Allow USB debugging?" prompt, which is worth naming outright.
            [] => Err(NautilusError::ConfigError(format!(
                "no usable Android device; adb reports: {}. An `unauthorized` device needs the \
                 on-screen 'Allow USB debugging' prompt accepted.",
                listed
                    .iter()
                    .map(|d| format!("{} ({})", d.serial, d.state))
                    .collect::<Vec<_>>()
                    .join(", ")
            ))),
            [only] => Ok(Self::new(Some(only.serial.clone()))),
            many => Err(NautilusError::ConfigError(format!(
                "{} devices attached; set VOICE_AGENT_ANDROID to one serial: {}",
                many.len(),
                many.iter()
                    .map(|d| d.serial.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ))),
        }
    }

    /// The serial this handle is pinned to, if any.
    pub fn serial(&self) -> Option<&str> {
        self.serial.as_deref()
    }

    fn base_args(&self) -> Vec<String> {
        match &self.serial {
            Some(s) => vec!["-s".to_string(), s.clone()],
            None => Vec::new(),
        }
    }

    /// Run `adb <args>` and return stdout as bytes.
    fn adb_raw(&self, args: &[&str]) -> Result<Vec<u8>, NautilusError> {
        let mut cmd = Command::new(&self.adb);
        cmd.args(self.base_args());
        cmd.args(args);
        let out = run_with_timeout(cmd, self.timeout, &self.adb)?;

        if !out.status_ok {
            return Err(NautilusError::InternalError(format!(
                "adb {} failed ({}): {}",
                args.join(" "),
                out.status_text,
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(out.stdout)
    }

    /// Run `adb <args>` and return stdout as text.
    fn adb_text(&self, args: &[&str]) -> Result<String, NautilusError> {
        Ok(String::from_utf8_lossy(&self.adb_raw(args)?).into_owned())
    }

    /// Run a command on the device shell. Arguments are quoted for the *device's*
    /// shell, which adb starts on the far side.
    fn shell(&self, argv: &[&str]) -> Result<String, NautilusError> {
        let line = argv
            .iter()
            .map(|a| shell_quote(a))
            .collect::<Vec<_>>()
            .join(" ");
        self.adb_text(&["shell", &line])
    }

    /// `adb devices -l`.
    pub fn list_devices(&self) -> Result<Vec<DeviceInfo>, NautilusError> {
        // Deliberately not `self.adb_raw`: listing must never be scoped to -s.
        let mut cmd = Command::new(&self.adb);
        cmd.args(["devices", "-l"]);
        let out = run_with_timeout(cmd, self.timeout, &self.adb)?;
        if !out.status_ok {
            return Err(NautilusError::InternalError(format!(
                "adb devices failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(parse_devices(&String::from_utf8_lossy(&out.stdout)))
    }

    /// The current, rotation-applied display geometry.
    pub fn geometry(&self) -> Result<Geometry, NautilusError> {
        if let Some((g, at)) = *self.geometry.lock() {
            if at.elapsed() < GEOMETRY_TTL {
                return Ok(g);
            }
        }
        let g = self.read_geometry()?;
        *self.geometry.lock() = Some((g, Instant::now()));
        Ok(g)
    }

    /// Drop the cached geometry, forcing the next read to hit the device.
    pub fn invalidate_geometry(&self) {
        *self.geometry.lock() = None;
    }

    fn read_geometry(&self) -> Result<Geometry, NautilusError> {
        let dump = self.shell(&["dumpsys", "window", "displays"])?;
        let rotation = parse_rotation(&dump).unwrap_or(0);

        // `cur=` is already rotation-applied; prefer it over everything else.
        if let Some((width, height)) = parse_cur_size(&dump) {
            return Ok(Geometry {
                width,
                height,
                rotation,
            });
        }

        // Fallback: `wm size` gives the panel, so apply the rotation ourselves.
        let wm = self.shell(&["wm", "size"])?;
        let (w, h) = parse_wm_size(&wm).ok_or_else(|| {
            NautilusError::InternalError(
                "could not determine display size from `dumpsys window displays` or `wm size`"
                    .to_string(),
            )
        })?;
        let (width, height) = if rotation % 2 == 1 { (h, w) } else { (w, h) };
        Ok(Geometry {
            width,
            height,
            rotation,
        })
    }

    /// Package/activity of the focused window, e.g. `com.foo.bar/.MainActivity`.
    pub fn focused_app(&self) -> Option<String> {
        let dump = self.shell(&["dumpsys", "window"]).ok()?;
        parse_focused_app(&dump)
    }

    /// A PNG of the current screen. Its pixel dimensions match [`Geometry`].
    pub fn screenshot(&self) -> Result<Vec<u8>, NautilusError> {
        let png = self.adb_raw(&["exec-out", "screencap", "-p"])?;
        if png.len() < 8 || &png[..8] != b"\x89PNG\r\n\x1a\n" {
            return Err(NautilusError::InternalError(format!(
                "screencap did not return a PNG ({} bytes). Some devices need \
                 `adb shell screencap -p /sdcard/x.png` + pull instead of exec-out.",
                png.len()
            )));
        }
        Ok(png)
    }

    /// Turn a normalized `0.0..=1.0` pair into device pixels.
    pub fn to_pixels(&self, x: f64, y: f64) -> Result<Pixel, NautilusError> {
        let g = self.geometry()?;
        Ok((denormalize(x, g.width)?, denormalize(y, g.height)?))
    }

    pub fn tap(&self, x: f64, y: f64) -> Result<Pixel, NautilusError> {
        let (px, py) = self.to_pixels(x, y)?;
        self.shell(&["input", "tap", &px.to_string(), &py.to_string()])?;
        Ok((px, py))
    }

    pub fn swipe(
        &self,
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
        duration_ms: u32,
    ) -> Result<(Pixel, Pixel), NautilusError> {
        let (ax, ay) = self.to_pixels(x1, y1)?;
        let (bx, by) = self.to_pixels(x2, y2)?;
        self.shell(&[
            "input",
            "swipe",
            &ax.to_string(),
            &ay.to_string(),
            &bx.to_string(),
            &by.to_string(),
            &duration_ms.to_string(),
        ])?;
        Ok(((ax, ay), (bx, by)))
    }

    /// A press-and-hold. Android has no dedicated verb; a zero-distance swipe
    /// with a duration is how `input` expresses one.
    pub fn long_press(&self, x: f64, y: f64, duration_ms: u32) -> Result<Pixel, NautilusError> {
        let (px, py) = self.to_pixels(x, y)?;
        self.shell(&[
            "input",
            "swipe",
            &px.to_string(),
            &py.to_string(),
            &px.to_string(),
            &py.to_string(),
            &duration_ms.to_string(),
        ])?;
        Ok((px, py))
    }

    pub fn key(&self, key: &str) -> Result<String, NautilusError> {
        let code = normalize_keycode(key)?;
        self.shell(&["input", "keyevent", &code])?;
        Ok(code)
    }

    pub fn text(&self, text: &str) -> Result<(), NautilusError> {
        if text.is_empty() {
            return Err(NautilusError::ConfigError("text is empty".to_string()));
        }
        // `input text` speaks ASCII only. Non-ASCII silently types nothing,
        // which reads as "the tap missed" and costs an hour. Say so instead.
        if !text.is_ascii() {
            return Err(NautilusError::ConfigError(format!(
                "`input text` can only type ASCII; {:?} contains non-ASCII. Typing Japanese needs \
                 an IME such as ADBKeyboard (com.android.adbkeyboard) driven by a broadcast.",
                text
            )));
        }
        // `input text` uses %s for a space and treats % specially.
        let encoded = text.replace('%', "%%").replace(' ', "%s");
        self.shell(&["input", "text", &encoded])?;
        Ok(())
    }

    /// Bring an app to the front by package name.
    ///
    /// Resolves the launcher activity and starts it explicitly. `monkey -p` is
    /// the usual one-liner for this and is *not* used: on a real device it hung
    /// for over 20s against a large game, survived the adb client being killed
    /// (killing adb does not kill the on-device process), and never started the
    /// app. `am start` dispatches an intent and returns.
    pub fn launch_app(&self, package: &str) -> Result<String, NautilusError> {
        if package.is_empty()
            || !package
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_')
        {
            return Err(NautilusError::ConfigError(format!(
                "not a package name: {package:?}"
            )));
        }

        let resolved = self.shell(&[
            "cmd",
            "package",
            "resolve-activity",
            "--brief",
            "-c",
            "android.intent.category.LAUNCHER",
            package,
        ])?;
        let component = parse_resolved_activity(&resolved, package).ok_or_else(|| {
            NautilusError::ConfigError(format!(
                "no launchable activity for {package:?}: {}. Check the package name with \
                 `adb shell pm list packages`.",
                resolved.trim()
            ))
        })?;

        let out = self.shell(&[
            "am",
            "start",
            "-a",
            "android.intent.action.MAIN",
            "-c",
            "android.intent.category.LAUNCHER",
            "-n",
            &component,
        ])?;
        // `am start` exits 0 while printing its failure, so read what it said.
        if out.contains("Error:") || out.contains("does not exist") {
            return Err(NautilusError::InternalError(format!(
                "could not launch {component}: {}",
                out.trim()
            )));
        }
        Ok(component)
    }
}

// ============================================================================
// Pure parsing / conversion helpers
//
// Kept free of any process work so they can be tested against real captured
// device output with no device attached.
// ============================================================================

/// Map `0.0..=1.0` onto `0..extent-1`.
pub(crate) fn denormalize(n: f64, extent: u32) -> Result<i64, NautilusError> {
    if !n.is_finite() || !(0.0..=1.0).contains(&n) {
        return Err(NautilusError::ConfigError(format!(
            "coordinate {n} is out of range; coordinates are normalized 0.0..=1.0, not pixels"
        )));
    }
    if extent == 0 {
        return Err(NautilusError::InternalError(
            "display extent is 0".to_string(),
        ));
    }
    let px = (n * extent as f64).round() as i64;
    Ok(px.clamp(0, extent as i64 - 1))
}

/// `... init=752x1336 266dpi cur=1336x752 app=1336x725 ...`
pub(crate) fn parse_cur_size(dump: &str) -> Option<(u32, u32)> {
    dump.split_whitespace()
        .find_map(|t| t.strip_prefix("cur="))
        .and_then(parse_wxh)
}

/// `Physical size: 752x1336`
pub(crate) fn parse_wm_size(s: &str) -> Option<(u32, u32)> {
    s.lines()
        .find_map(|l| l.split("size:").nth(1))
        .and_then(|v| parse_wxh(v.trim()))
}

fn parse_wxh(s: &str) -> Option<(u32, u32)> {
    let (w, h) = s.split_once('x')?;
    let digits = |t: &str| {
        let t: String = t.chars().take_while(char::is_ascii_digit).collect();
        t.parse::<u32>().ok()
    };
    match (digits(w), digits(h)) {
        (Some(w), Some(h)) if w > 0 && h > 0 => Some((w, h)),
        _ => None,
    }
}

/// `mRotation=1`
pub(crate) fn parse_rotation(dump: &str) -> Option<u32> {
    dump.split_whitespace()
        .find_map(|t| t.strip_prefix("mRotation="))
        .and_then(|v| {
            v.trim_end_matches(|c: char| !c.is_ascii_digit())
                .parse::<u32>()
                .ok()
        })
        .map(|r| r % 4)
}

/// `mCurrentFocus=Window{cdf7a0c u0 com.android.deskclock/com.android.deskclock.DeskClock}`
pub(crate) fn parse_focused_app(dump: &str) -> Option<String> {
    let line = dump.lines().find(|l| l.contains("mCurrentFocus="))?;
    let inside = line.split_once('{')?.1;
    let name = inside
        .trim_end_matches('}')
        .split_whitespace()
        .last()?
        .trim_end_matches('}');
    (!name.is_empty() && name != "null").then(|| name.to_string())
}

/// The `package/activity` line from `cmd package resolve-activity --brief`.
///
/// The command prints a `priority=... ` preamble line first, so the component
/// is found by prefix rather than by position.
pub(crate) fn parse_resolved_activity(out: &str, package: &str) -> Option<String> {
    let prefix = format!("{package}/");
    out.lines()
        .map(str::trim)
        .find(|l| l.starts_with(&prefix) && l.len() > prefix.len())
        .map(str::to_string)
}

/// Serial / state / model from `adb devices -l`.
pub(crate) fn parse_devices(out: &str) -> Vec<DeviceInfo> {
    out.lines()
        .skip_while(|l| !l.starts_with("List of devices"))
        .skip(1)
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let serial = parts.next()?.to_string();
            let state = parts.next()?.to_string();
            let model = parts
                .find_map(|t| t.strip_prefix("model:"))
                .map(str::to_string);
            Some(DeviceInfo {
                serial,
                state,
                model,
            })
        })
        .collect()
}

/// Width/height straight out of a PNG's IHDR, so a screenshot can be checked
/// against the geometry we believed.
pub(crate) fn png_dimensions(png: &[u8]) -> Option<(u32, u32)> {
    if png.len() < 24 || &png[..8] != b"\x89PNG\r\n\x1a\n" {
        return None;
    }
    let w = u32::from_be_bytes(png[16..20].try_into().ok()?);
    let h = u32::from_be_bytes(png[20..24].try_into().ok()?);
    (w > 0 && h > 0).then_some((w, h))
}

/// Accept `BACK` or `KEYCODE_BACK`, and refuse anything that is not a keycode.
///
/// The charset check is what keeps a model-supplied string from becoming device
/// shell syntax.
pub(crate) fn normalize_keycode(key: &str) -> Result<String, NautilusError> {
    let k = key.trim().to_ascii_uppercase();
    let k = if k.starts_with("KEYCODE_") {
        k
    } else {
        format!("KEYCODE_{k}")
    };
    let body = &k["KEYCODE_".len()..];
    if body.is_empty() || !body.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
        return Err(NautilusError::ConfigError(format!(
            "not a keycode: {key:?} (expected e.g. BACK, HOME, ENTER, DPAD_UP)"
        )));
    }
    Ok(k)
}

/// Quote one argument for the device-side shell that `adb shell` starts.
pub(crate) fn shell_quote(s: &str) -> String {
    if !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-./:=+,@%".contains(&b))
    {
        return s.to_string();
    }
    format!("'{}'", s.replace('\'', r"'\''"))
}

// ============================================================================
// Process runner
// ============================================================================

struct RunOutput {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    status_ok: bool,
    status_text: String,
}

/// Run a command, killing it if it outruns `timeout`.
///
/// stdout is drained on its own thread: a screenshot is ~200KB, which is more
/// than a pipe buffer holds, so waiting on exit before reading would deadlock.
fn run_with_timeout(
    mut cmd: Command,
    timeout: Duration,
    program: &str,
) -> Result<RunOutput, NautilusError> {
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| {
            NautilusError::ConfigError(format!(
                "could not run `{program}`: {e}. Install Android platform-tools, or set ADB to \
                 its path."
            ))
        })?;

    let drain = |pipe: Option<Box<dyn Read + Send>>| {
        let (tx, rx) = channel::bounded::<Vec<u8>>(1);
        if let Some(mut pipe) = pipe {
            std::thread::spawn(move || {
                let mut buf = Vec::new();
                let _ = pipe.read_to_end(&mut buf);
                let _ = tx.send(buf);
            });
        }
        rx
    };
    let out_rx = drain(
        child
            .stdout
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let err_rx = drain(
        child
            .stderr
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );

    let stdout = match out_rx.recv_timeout(timeout) {
        Ok(b) => b,
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(NautilusError::InternalError(format!(
                "`{program}` did not finish within {}s and was killed",
                timeout.as_secs()
            )));
        }
    };
    let status = child
        .wait()
        .map_err(|e| NautilusError::InternalError(format!("waiting on `{program}`: {e}")))?;
    let stderr = err_rx
        .recv_timeout(Duration::from_secs(2))
        .unwrap_or_default();

    Ok(RunOutput {
        stdout,
        stderr,
        status_ok: status.success(),
        status_text: status.to_string(),
    })
}
