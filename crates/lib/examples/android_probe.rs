//! Drives the Android primitives against a **real** device, through the same
//! [`ToolHandler`] surface the backend's model sees.
//!
//! Not a test: it needs a device on `adb`. It exists because the unit tests can
//! only check the parsers against captured strings — whether a normalized
//! coordinate actually lands on the thing you saw in the screenshot is a claim
//! only hardware can settle.
//!
//! ```bash
//! cd crates
//! cargo run --example android_probe -- info
//! cargo run --example android_probe -- observe /tmp/screen.png
//! cargo run --example android_probe -- tap 0.91 0.54
//! cargo run --example android_probe -- swipe 0.75 0.53 0.22 0.53 300
//! cargo run --example android_probe -- key BACK
//! cargo run --example android_probe -- launch com.farlightgames.samo.gp.jp
//! cargo run --example android_probe -- tools        # what the model would see
//! ```
//!
//! The device comes from `VOICE_AGENT_ANDROID` (a serial, or `auto`).

use std::sync::Arc;

use nautilus_core::android::{android_tools, Device};
use nautilus_core::tool::ToolHandler;
use serde_json::json;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("info");

    let spec = std::env::var("VOICE_AGENT_ANDROID").unwrap_or_else(|_| "auto".to_string());
    let device = Arc::new(Device::resolve(&spec).unwrap_or_else(|e| {
        eprintln!("error: {e}");
        std::process::exit(1);
    }));
    let tools = android_tools(device);
    let find = |name: &str| -> &dyn ToolHandler {
        tools
            .iter()
            .find(|t| t.name() == name)
            .map(|t| t.as_ref())
            .unwrap_or_else(|| panic!("no tool named {name}"))
    };

    let num = |i: usize| -> f64 {
        args.get(i)
            .and_then(|s| s.parse().ok())
            .unwrap_or_else(|| panic!("argument {i} must be a number"))
    };

    let (tool, params) = match cmd {
        "tools" => {
            // What the backend registers as dynamicTools: the exact text the
            // model reads when deciding whether a tool is the right one.
            for t in &tools {
                println!("{}\n    {}\n", t.name(), t.description());
            }
            return;
        }
        "info" => ("android_info", json!({})),
        "observe" => ("android_observe", json!({})),
        "tap" => ("android_tap", json!({ "x": num(1), "y": num(2) })),
        "long_press" => (
            "android_long_press",
            json!({ "x": num(1), "y": num(2), "duration_ms": 600 }),
        ),
        "swipe" => (
            "android_swipe",
            json!({
                "x1": num(1), "y1": num(2), "x2": num(3), "y2": num(4),
                "duration_ms": args.get(5).and_then(|s| s.parse::<u32>().ok()).unwrap_or(300)
            }),
        ),
        "key" => (
            "android_key",
            json!({ "key": args.get(1).cloned().unwrap_or_default() }),
        ),
        "text" => (
            "android_text",
            json!({ "text": args.get(1).cloned().unwrap_or_default() }),
        ),
        "wait" => ("android_wait", json!({ "seconds": num(1) })),
        "launch" => (
            "android_launch_app",
            json!({ "package": args.get(1).cloned().unwrap_or_default() }),
        ),
        other => {
            eprintln!("unknown command {other:?}; try: tools info observe tap long_press swipe key text wait launch");
            std::process::exit(2);
        }
    };

    let started = std::time::Instant::now();
    match find(tool).call(params) {
        Ok(result) => {
            println!(
                "{} ({}ms)\n{}",
                tool,
                started.elapsed().as_millis(),
                result.text
            );
            // An image only proves anything if it can be looked at.
            if let Some(img) = result.images.first() {
                let path = args
                    .get(1)
                    .filter(|_| cmd == "observe")
                    .cloned()
                    .unwrap_or_else(|| "/tmp/android_probe.png".to_string());
                match base64_decode(&img.base64) {
                    Some(bytes) => {
                        std::fs::write(&path, &bytes).expect("write screenshot");
                        println!("wrote {} ({} bytes, {})", path, bytes.len(), img.media_type);
                    }
                    None => eprintln!("screenshot did not decode"),
                }
            }
        }
        Err(e) => {
            eprintln!("{tool} failed: {e}");
            std::process::exit(1);
        }
    }
}

fn base64_decode(s: &str) -> Option<Vec<u8>> {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.decode(s).ok()
}
