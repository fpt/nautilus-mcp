//! The model-facing Android primitives.
//!
//! These are deliberately *general* GUI operations — observe, tap, swipe, key,
//! text — and contain no knowledge of any particular app. The intent is that
//! composite skills ("open the build menu", "find the selected unit") are
//! discovered and composed on top of these rather than hand-written here.
//!
//! Two rules are baked into the surface:
//!
//! 1. **Coordinates are normalized `0.0..=1.0`**, so a discovered skill keeps
//!    working across devices and rotations. Pixels never reach the model.
//! 2. **No action reports success on its own.** `input tap` returns 0 whether it
//!    hit a button or empty space, so every description tells the caller to
//!    confirm with `android_observe`.

use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use serde_json::{json, Value};

use super::device::{png_dimensions, Device};
use crate::image::ImageContent;
use crate::tool::{ToolHandler, ToolResult};
use crate::NautilusError;

/// Longest `android_wait` we will honour, so a bad number cannot park a turn.
const MAX_WAIT_SECONDS: f64 = 30.0;

/// Default press duration for a long press.
const DEFAULT_LONG_PRESS_MS: u32 = 600;

/// Default swipe duration. Too fast and Android reads a swipe as a fling.
const DEFAULT_SWIPE_MS: u32 = 300;

fn arg_f64(args: &Value, key: &str) -> Result<f64, NautilusError> {
    args.get(key)
        .and_then(Value::as_f64)
        .ok_or_else(|| NautilusError::ConfigError(format!("missing number `{key}`")))
}

fn arg_str<'a>(args: &'a Value, key: &str) -> Result<&'a str, NautilusError> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| NautilusError::ConfigError(format!("missing string `{key}`")))
}

fn arg_u32(args: &Value, key: &str, default: u32) -> u32 {
    args.get(key)
        .and_then(Value::as_u64)
        .map(|v| v.min(u32::MAX as u64) as u32)
        .unwrap_or(default)
}

/// A normalized point, used by every positional tool.
fn point_schema(extra: Value) -> Value {
    let mut props = json!({
        "x": { "type": "number", "minimum": 0.0, "maximum": 1.0,
               "description": "Horizontal position, 0.0 = left edge, 1.0 = right edge." },
        "y": { "type": "number", "minimum": 0.0, "maximum": 1.0,
               "description": "Vertical position, 0.0 = top edge, 1.0 = bottom edge." }
    });
    if let (Some(p), Some(e)) = (props.as_object_mut(), extra.as_object()) {
        for (k, v) in e {
            p.insert(k.clone(), v.clone());
        }
    }
    json!({ "type": "object", "properties": props, "required": ["x", "y"] })
}

// ============================================================================
// android_observe
// ============================================================================

/// Screenshot + the context needed to act on it.
pub struct ObserveTool {
    device: Arc<Device>,
}

impl ObserveTool {
    pub fn new(device: Arc<Device>) -> Self {
        Self { device }
    }
}

impl ToolHandler for ObserveTool {
    fn name(&self) -> &str {
        "android_observe"
    }

    fn description(&self) -> &str {
        "Take a screenshot of the Android device and return it as an image. Use this to see the \
         current state before acting, and again afterwards to confirm what an action actually \
         did. The image you get back is the same coordinate space the tap/swipe tools use, so a \
         point that is 30% across the image is x=0.3."
    }

    fn parameters_schema(&self) -> Value {
        json!({ "type": "object", "properties": {}, "required": [] })
    }

    fn call(&self, _args: Value) -> Result<ToolResult, NautilusError> {
        // Rotation may have changed since the last action; never answer from cache here.
        self.device.invalidate_geometry();
        let geometry = self.device.geometry()?;
        let png = self.device.screenshot()?;
        let focused = self.device.focused_app();

        let mut text = format!(
            "Screen {}x{} (rotation {}).",
            geometry.width, geometry.height, geometry.rotation
        );
        if let Some(app) = &focused {
            text.push_str(&format!(" Focused app: {app}."));
        }

        // The whole coordinate story rests on the screenshot and the display
        // agreeing. If they ever diverge, taps are silently transposed, so
        // check it here rather than let it be debugged from missed taps.
        if let Some((pw, ph)) = png_dimensions(&png) {
            if (pw, ph) != (geometry.width, geometry.height) {
                text.push_str(&format!(
                    " WARNING: screenshot is {pw}x{ph} but the display reports {}x{}; \
                     coordinates may be offset.",
                    geometry.width, geometry.height
                ));
            }
        }

        let base64 = base64::engine::general_purpose::STANDARD.encode(&png);
        Ok(ToolResult::with_images(
            text,
            vec![ImageContent {
                base64,
                media_type: "image/png".to_string(),
            }],
        ))
    }
}

// ============================================================================
// android_info
// ============================================================================

/// The cheap half of `android_observe`: state without the picture.
pub struct InfoTool {
    device: Arc<Device>,
}

impl InfoTool {
    pub fn new(device: Arc<Device>) -> Self {
        Self { device }
    }
}

impl ToolHandler for InfoTool {
    fn name(&self) -> &str {
        "android_info"
    }

    fn description(&self) -> &str {
        "Report the Android device's screen size, rotation and focused app without taking a \
         screenshot. Cheaper than android_observe; use it to check whether an app launched or \
         the screen rotated."
    }

    fn parameters_schema(&self) -> Value {
        json!({ "type": "object", "properties": {}, "required": [] })
    }

    fn call(&self, _args: Value) -> Result<ToolResult, NautilusError> {
        self.device.invalidate_geometry();
        let g = self.device.geometry()?;
        let focused = self
            .device
            .focused_app()
            .unwrap_or_else(|| "unknown".into());
        Ok(ToolResult::text(format!(
            "serial={} screen={}x{} rotation={} focused={}",
            self.device.serial().unwrap_or("(default)"),
            g.width,
            g.height,
            g.rotation,
            focused
        )))
    }
}

// ============================================================================
// android_tap
// ============================================================================

pub struct TapTool {
    device: Arc<Device>,
}

impl TapTool {
    pub fn new(device: Arc<Device>) -> Self {
        Self { device }
    }
}

impl ToolHandler for TapTool {
    fn name(&self) -> &str {
        "android_tap"
    }

    fn description(&self) -> &str {
        "Tap the Android screen at a normalized position (0.0-1.0 of the width and height, as \
         seen in the latest android_observe image). A tap always reports success even when it \
         hits nothing, so call android_observe afterwards to see what changed. Tapping an \
         unidentified element is also a good way to learn what it is."
    }

    fn parameters_schema(&self) -> Value {
        point_schema(json!({}))
    }

    fn call(&self, args: Value) -> Result<ToolResult, NautilusError> {
        let (x, y) = (arg_f64(&args, "x")?, arg_f64(&args, "y")?);
        let (px, py) = self.device.tap(x, y)?;
        Ok(ToolResult::text(format!(
            "Tapped ({x:.3}, {y:.3}) = pixel ({px}, {py}). Observe to confirm the effect."
        )))
    }
}

// ============================================================================
// android_swipe
// ============================================================================

pub struct SwipeTool {
    device: Arc<Device>,
}

impl SwipeTool {
    pub fn new(device: Arc<Device>) -> Self {
        Self { device }
    }
}

impl ToolHandler for SwipeTool {
    fn name(&self) -> &str {
        "android_swipe"
    }

    fn description(&self) -> &str {
        "Drag from one normalized point to another on the Android screen. Use it to scroll lists, \
         pan a map, or drag an object. A longer duration_ms drags; a short one flings."
    }

    fn parameters_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "x1": { "type": "number", "minimum": 0.0, "maximum": 1.0, "description": "Start x." },
                "y1": { "type": "number", "minimum": 0.0, "maximum": 1.0, "description": "Start y." },
                "x2": { "type": "number", "minimum": 0.0, "maximum": 1.0, "description": "End x." },
                "y2": { "type": "number", "minimum": 0.0, "maximum": 1.0, "description": "End y." },
                "duration_ms": { "type": "integer", "minimum": 1,
                    "description": "Gesture duration in milliseconds (default 300)." }
            },
            "required": ["x1", "y1", "x2", "y2"]
        })
    }

    fn call(&self, args: Value) -> Result<ToolResult, NautilusError> {
        let ms = arg_u32(&args, "duration_ms", DEFAULT_SWIPE_MS).max(1);
        let (a, b) = self.device.swipe(
            arg_f64(&args, "x1")?,
            arg_f64(&args, "y1")?,
            arg_f64(&args, "x2")?,
            arg_f64(&args, "y2")?,
            ms,
        )?;
        Ok(ToolResult::text(format!(
            "Swiped pixel ({}, {}) -> ({}, {}) over {ms}ms. Observe to confirm.",
            a.0, a.1, b.0, b.1
        )))
    }
}

// ============================================================================
// android_long_press
// ============================================================================

pub struct LongPressTool {
    device: Arc<Device>,
}

impl LongPressTool {
    pub fn new(device: Arc<Device>) -> Self {
        Self { device }
    }
}

impl ToolHandler for LongPressTool {
    fn name(&self) -> &str {
        "android_long_press"
    }

    fn description(&self) -> &str {
        "Press and hold a normalized point on the Android screen. Many apps reveal a context \
         menu, a tooltip or a detail panel on a long press, which makes this a good way to \
         identify something you cannot name from the screenshot alone."
    }

    fn parameters_schema(&self) -> Value {
        point_schema(json!({
            "duration_ms": { "type": "integer", "minimum": 1,
                "description": "Hold time in milliseconds (default 600)." }
        }))
    }

    fn call(&self, args: Value) -> Result<ToolResult, NautilusError> {
        let ms = arg_u32(&args, "duration_ms", DEFAULT_LONG_PRESS_MS).max(1);
        let (px, py) = self
            .device
            .long_press(arg_f64(&args, "x")?, arg_f64(&args, "y")?, ms)?;
        Ok(ToolResult::text(format!(
            "Held pixel ({px}, {py}) for {ms}ms. Observe to confirm."
        )))
    }
}

// ============================================================================
// android_key
// ============================================================================

pub struct KeyTool {
    device: Arc<Device>,
}

impl KeyTool {
    pub fn new(device: Arc<Device>) -> Self {
        Self { device }
    }
}

impl ToolHandler for KeyTool {
    fn name(&self) -> &str {
        "android_key"
    }

    fn description(&self) -> &str {
        "Send a hardware key to the Android device. Common keys: BACK (go back / close a dialog), \
         HOME, APP_SWITCH, ENTER, ESCAPE, DEL, DPAD_UP/DOWN/LEFT/RIGHT, VOLUME_UP, POWER. BACK is \
         usually the safest way out of a screen you did not mean to open."
    }

    fn parameters_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "key": { "type": "string",
                    "description": "Key name, with or without the KEYCODE_ prefix, e.g. \"BACK\"." }
            },
            "required": ["key"]
        })
    }

    fn call(&self, args: Value) -> Result<ToolResult, NautilusError> {
        let code = self.device.key(arg_str(&args, "key")?)?;
        Ok(ToolResult::text(format!(
            "Sent {code}. Observe to confirm."
        )))
    }
}

// ============================================================================
// android_text
// ============================================================================

pub struct TextTool {
    device: Arc<Device>,
}

impl TextTool {
    pub fn new(device: Arc<Device>) -> Self {
        Self { device }
    }
}

impl ToolHandler for TextTool {
    fn name(&self) -> &str {
        "android_text"
    }

    fn description(&self) -> &str {
        "Type ASCII text into whatever field currently has focus on the Android device. Tap the \
         field first. Non-ASCII text (including Japanese) cannot be typed this way and will be \
         rejected."
    }

    fn parameters_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": { "text": { "type": "string", "description": "ASCII text to type." } },
            "required": ["text"]
        })
    }

    fn call(&self, args: Value) -> Result<ToolResult, NautilusError> {
        let text = arg_str(&args, "text")?;
        self.device.text(text)?;
        Ok(ToolResult::text(format!(
            "Typed {} character(s). Observe to confirm it landed in the right field.",
            text.chars().count()
        )))
    }
}

// ============================================================================
// android_wait
// ============================================================================

/// Waiting is a real primitive here: animations, loading screens and server
/// round-trips all mean the screen right after an action is not the screen that
/// action produces.
pub struct WaitTool;

impl ToolHandler for WaitTool {
    fn name(&self) -> &str {
        "android_wait"
    }

    fn description(&self) -> &str {
        "Pause before observing again. Use it after an action that starts an animation, a screen \
         transition or a load, so that android_observe sees the settled screen rather than a \
         frame mid-transition."
    }

    fn parameters_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "seconds": { "type": "number", "minimum": 0.0, "maximum": MAX_WAIT_SECONDS,
                    "description": "How long to wait, up to 30." }
            },
            "required": ["seconds"]
        })
    }

    fn call(&self, args: Value) -> Result<ToolResult, NautilusError> {
        let s = arg_f64(&args, "seconds")?;
        if !s.is_finite() || s < 0.0 {
            return Err(NautilusError::ConfigError(format!("bad wait: {s}")));
        }
        let s = s.min(MAX_WAIT_SECONDS);
        std::thread::sleep(Duration::from_secs_f64(s));
        Ok(ToolResult::text(format!("Waited {s:.2}s.")))
    }
}

// ============================================================================
// android_launch_app
// ============================================================================

pub struct LaunchAppTool {
    device: Arc<Device>,
}

impl LaunchAppTool {
    pub fn new(device: Arc<Device>) -> Self {
        Self { device }
    }
}

impl ToolHandler for LaunchAppTool {
    fn name(&self) -> &str {
        "android_launch_app"
    }

    fn description(&self) -> &str {
        "Bring an Android app to the foreground by package name (e.g. \
         com.farlightgames.samo.gp.jp). Games can take many seconds to reach a playable screen, \
         so wait and observe after launching."
    }

    fn parameters_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "package": { "type": "string", "description": "Android package name." }
            },
            "required": ["package"]
        })
    }

    fn call(&self, args: Value) -> Result<ToolResult, NautilusError> {
        let package = arg_str(&args, "package")?;
        let component = self.device.launch_app(package)?;
        Ok(ToolResult::text(format!(
            "Started {component}. A game can take tens of seconds to reach a playable screen: \
             wait, then observe."
        )))
    }
}

// ============================================================================
// Registration
// ============================================================================

/// Every Android primitive, sharing one device handle.
pub fn android_tools(device: Arc<Device>) -> Vec<Box<dyn ToolHandler>> {
    vec![
        Box::new(ObserveTool::new(device.clone())),
        Box::new(InfoTool::new(device.clone())),
        Box::new(TapTool::new(device.clone())),
        Box::new(SwipeTool::new(device.clone())),
        Box::new(LongPressTool::new(device.clone())),
        Box::new(KeyTool::new(device.clone())),
        Box::new(TextTool::new(device.clone())),
        Box::new(WaitTool),
        Box::new(LaunchAppTool::new(device)),
    ]
}
