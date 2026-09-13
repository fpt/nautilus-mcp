//! Android GUI automation over `adb`.
//!
//! A small set of general primitives — observe, tap, swipe, long-press, key,
//! text, wait, launch — served to the backend as client tools. There is no
//! per-app code here on purpose: the intent (see the project plan) is that
//! reusable composite skills are *discovered* on top of these primitives rather
//! than written by hand for each game.
//!
//! # Enabling
//!
//! Off unless `VOICE_AGENT_ANDROID` is set, so a user with no phone attached
//! never sees these tools:
//!
//! ```text
//! VOICE_AGENT_ANDROID=auto          # the only attached device
//! VOICE_AGENT_ANDROID=71646875653313  # a specific serial
//! ```
//!
//! `ADB` overrides the `adb` binary.
//!
//! # Current limits
//!
//! - **No hover.** `adb shell input` has no pointer, so the
//!   hover → tooltip → OCR loop is not expressible yet; long-press is the
//!   nearest substitute. scrcpy's control socket is what unlocks a real
//!   pointer, and is the natural next transport behind [`Device`].
//! - **Latency.** Each `input` call pays ~650ms starting Android's `input`
//!   binary, against ~400ms for a screenshot and ~80ms for geometry (measured
//!   on a Retroid Pocket 3+). The scrcpy control socket sends a binary message
//!   instead and would cut the input cost to roughly nothing.
//! - **ASCII only** for typed text; see [`Device::text`].
//! - **No crop / OCR / image-diff** yet — those need an image decoder in this
//!   crate, and are the other half of the plan's primitive set.

mod device;
mod tools;

pub use device::{Device, DeviceInfo, Geometry, Pixel};
pub use tools::android_tools;

/// Environment variable that enables the Android tools and picks the device.
pub const ENABLE_ENV: &str = "VOICE_AGENT_ANDROID";

/// Build the Android tools if the user asked for them.
///
/// Returns `None` when [`ENABLE_ENV`] is unset or empty. A set-but-unusable
/// value (no device, an unauthorized one, two attached) is an `Err`: the user
/// explicitly asked for Android, so silence would be the wrong answer.
pub fn maybe_tools() -> Option<Result<Vec<Box<dyn crate::tool::ToolHandler>>, crate::NautilusError>>
{
    let spec = std::env::var(ENABLE_ENV).ok()?;
    if spec.trim().is_empty() {
        return None;
    }
    Some(Device::resolve(&spec).map(|d| android_tools(std::sync::Arc::new(d))))
}

#[cfg(test)]
mod tests {
    use super::device::*;

    /// Real output from `adb shell dumpsys window displays` on a Retroid
    /// Pocket 3+ held in landscape.
    const DISPLAYS: &str = "  Display: mDisplayId=0\n    init=752x1336 266dpi cur=1336x752 \
         app=1336x725 rng=752x685-1336x1269\n  mCurrentFocus=Window{6898528 u0 \
         com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher}\n  \
         DisplayRotation\n    mRotation=1 mDeferredRotationPauseCount=0\n";

    /// The whole point of reading `cur=`: the panel is portrait, the display is
    /// not. `wm size` would have said 752x1336 and transposed every tap.
    #[test]
    fn rotated_display_size_comes_from_cur_not_the_panel() {
        assert_eq!(parse_cur_size(DISPLAYS), Some((1336, 752)));
        assert_eq!(parse_wm_size("Physical size: 752x1336"), Some((752, 1336)));
        assert_eq!(parse_rotation(DISPLAYS), Some(1));
    }

    #[test]
    fn missing_rotation_and_size_are_absent_not_zero() {
        assert_eq!(parse_rotation("no rotation here"), None);
        assert_eq!(parse_cur_size("init=752x1336"), None);
        assert_eq!(parse_wm_size("Physical size: xyz"), None);
        assert_eq!(parse_wm_size(""), None);
    }

    #[test]
    fn focused_app_is_the_package_activity_pair() {
        assert_eq!(
            parse_focused_app(DISPLAYS).as_deref(),
            Some("com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher")
        );
        assert_eq!(parse_focused_app("mCurrentFocus=null"), None);
        assert_eq!(parse_focused_app("nothing"), None);
    }

    #[test]
    fn devices_listing_keeps_serial_state_and_model() {
        let out = "List of devices attached\n71646875653313         device \
                   usb:1048576X product:ums512_1h10_Natv model:Retroid_Pocket_3_Plus \
                   device:ums512_1h10 transport_id:2\n\n";
        assert_eq!(
            parse_devices(out),
            vec![DeviceInfo {
                serial: "71646875653313".into(),
                state: "device".into(),
                model: Some("Retroid_Pocket_3_Plus".into()),
            }]
        );
        assert!(parse_devices("List of devices attached\n\n").is_empty());
    }

    /// An `unauthorized` device must survive parsing so the caller can explain
    /// the USB-debugging prompt rather than report "no devices".
    #[test]
    fn unauthorized_device_is_listed_not_dropped() {
        let out = "List of devices attached\nABC123\tunauthorized\n";
        let got = parse_devices(out);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].state, "unauthorized");
        assert_eq!(got[0].model, None);
    }

    /// `resolve-activity --brief` prints a `priority=...` preamble before the
    /// component, so the line is found by prefix, not by position.
    #[test]
    fn launcher_activity_is_found_past_the_preamble() {
        let out = "priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false\n\
                   com.farlightgames.samo.gp.jp/com.harry.engine.MainActivity\n";
        assert_eq!(
            parse_resolved_activity(out, "com.farlightgames.samo.gp.jp").as_deref(),
            Some("com.farlightgames.samo.gp.jp/com.harry.engine.MainActivity")
        );
        assert_eq!(parse_resolved_activity(out, "com.other.app"), None);
        assert_eq!(
            parse_resolved_activity("No activity found\n", "com.farlightgames.samo.gp.jp"),
            None
        );
    }

    #[test]
    fn normalized_coordinates_span_the_display() {
        assert_eq!(denormalize(0.0, 1336).unwrap(), 0);
        assert_eq!(denormalize(1.0, 1336).unwrap(), 1335);
        assert_eq!(denormalize(0.5, 1336).unwrap(), 668);
    }

    /// Pixels passed where a fraction belongs must not be silently clamped to
    /// the edge — that reads as "the tap missed" forever.
    #[test]
    fn pixel_coordinates_are_rejected_not_clamped() {
        for bad in [1213.0, -0.1, f64::NAN, f64::INFINITY] {
            assert!(denormalize(bad, 1336).is_err(), "{bad} should be rejected");
        }
    }

    #[test]
    fn keycodes_accept_either_spelling_and_reject_shell_syntax() {
        assert_eq!(normalize_keycode("back").unwrap(), "KEYCODE_BACK");
        assert_eq!(normalize_keycode("KEYCODE_HOME").unwrap(), "KEYCODE_HOME");
        assert_eq!(normalize_keycode(" dpad_up ").unwrap(), "KEYCODE_DPAD_UP");
        for bad in ["", "BACK; rm -rf /", "a b", "$(x)"] {
            assert!(
                normalize_keycode(bad).is_err(),
                "{bad:?} should be rejected"
            );
        }
    }

    /// `adb shell` starts a shell on the device, so arguments are quoted for
    /// *that* shell, not just passed as argv.
    #[test]
    fn shell_quoting_contains_metacharacters() {
        assert_eq!(shell_quote("input"), "input");
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
        assert_eq!(shell_quote("; rm -rf /"), r"'; rm -rf /'");
        assert_eq!(shell_quote(""), "''");
    }

    #[test]
    fn png_header_yields_dimensions() {
        let mut png = vec![0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'];
        png.extend_from_slice(&[0, 0, 0, 13]);
        png.extend_from_slice(b"IHDR");
        png.extend_from_slice(&1336u32.to_be_bytes());
        png.extend_from_slice(&752u32.to_be_bytes());
        assert_eq!(png_dimensions(&png), Some((1336, 752)));
        assert_eq!(png_dimensions(b"not a png at all......."), None);
        assert_eq!(png_dimensions(&[]), None);
    }
}
