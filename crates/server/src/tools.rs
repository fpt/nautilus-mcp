//! The portable tools: the Android primitives (forwarded to `nautilus_core`),
//! and the frame tools that work on what they capture. No OCR: the model
//! reading a crop does better than tesseract did on game text — see CLAUDE.md.
//! `nautilus_status`, which explains anything absent, is the hub's.

use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;

use nautilus_core::image::{decode_png_base64, encode_png_base64};
use nautilus_core::{AndroidController, RawImage, ToolSpec};
use serde_json::{json, Value};

use crate::frames::{Frame, FrameStore, NormRect};
use crate::mcp::{Args, Image, Tool, ToolFailure, ToolOutput};

pub type Frames = Rc<RefCell<FrameStore>>;

fn frame_id_property() -> Value {
    json!({ "type": "string",
            "description": "Frame to work on, from android_observe. Omit for the most recent capture." })
}

fn opt_str<'a>(args: &'a Args, key: &str) -> Option<&'a str> {
    args.get(key).and_then(Value::as_str)
}

/// Resolve `frame_id` and `region`. A `None` area means the whole frame.
fn resolve(args: &Args, frames: &Frames) -> Result<(Rc<Frame>, Option<NormRect>), ToolFailure> {
    if args.contains_key("region_id") {
        return Err(ToolFailure::new(
            "region_id needs image_regions, which this build does not have (it is Vision-based \
             and macOS-only). Pass an explicit `region` instead.",
        ));
    }
    let frame = frames.borrow().require(opt_str(args, "frame_id"), false)?;
    Ok((frame, NormRect::from_json(args.get("region"))))
}

// ============================================================================
// Android
// ============================================================================

/// Android tools that only look. Everything else — `android_wait` included —
/// is assumed to change the world, so a primitive added on the Rust side later
/// is stale-safe without anyone remembering to list it here.
const OBSERVATIONAL: [&str; 2] = ["android_observe", "android_info"];

pub struct AndroidTool {
    controller: Rc<AndroidController>,
    spec: ToolSpec,
    schema: Value,
    frames: Frames,
}

impl AndroidTool {
    /// Run the primitive and register any image it produced as a frame.
    fn run(&self, args: &Args) -> Result<ToolOutput, ToolFailure> {
        let output = self.controller.call(
            self.spec.name.clone(),
            Value::Object(args.clone()).to_string(),
        )?;
        if !OBSERVATIONAL.contains(&self.spec.name.as_str()) {
            self.frames.borrow_mut().world_changed();
        }
        let mut text = output.text;
        if let Some(first) = output.images.first() {
            if let Ok(decoded) = decode_png_base64(&first.base64) {
                let f = self.frames.borrow_mut().register(decoded, "android");
                text.push_str(&format!(
                    " frame_id={} — crop or diff it without re-capturing.",
                    f.id
                ));
            }
        }
        let images = output
            .images
            .into_iter()
            .map(|i| Image {
                base64: i.base64,
                mime_type: i.media_type,
            })
            .collect();
        Ok(ToolOutput { text, images })
    }
}

impl Tool for AndroidTool {
    fn name(&self) -> String {
        self.spec.name.clone()
    }
    fn description(&self) -> String {
        self.spec.description.clone()
    }
    fn input_schema(&self) -> Value {
        self.schema.clone()
    }
    fn call(&self, args: &Args) -> Result<ToolOutput, ToolFailure> {
        self.run(args)
    }
}

/// Bind a device and wrap every primitive it offers. Fails with the reason when no usable device is attached.
pub fn android_tools(
    serial: Option<String>,
    frames: &Frames,
) -> Result<Vec<Box<dyn Tool>>, String> {
    let controller = Rc::new(AndroidController::new(serial).map_err(|e| e.to_string())?);
    let mut tools: Vec<Box<dyn Tool>> = Vec::new();
    for spec in controller.tools() {
        let schema = serde_json::from_str(&spec.input_schema)
            .unwrap_or_else(|_| json!({ "type": "object", "properties": {} }));
        tools.push(Box::new(AndroidTool {
            controller: controller.clone(),
            spec,
            schema,
            frames: frames.clone(),
        }));
    }
    Ok(tools)
}

// ============================================================================
// image_crop
// ============================================================================

pub struct ImageCropTool {
    pub frames: Frames,
}

impl Tool for ImageCropTool {
    fn name(&self) -> String {
        "image_crop".into()
    }
    fn description(&self) -> String {
        "Cut a region out of a captured frame and return it as an image, plus a new frame_id for \
         the crop. Use it to look closely at something too small to read in the full frame. The \
         crop remembers where it came from, so anything you find in it still reports whole-frame \
         coordinates."
            .into()
    }
    fn input_schema(&self) -> Value {
        json!({ "type": "object",
                "properties": { "frame_id": frame_id_property(), "region": NormRect::schema() },
                "required": ["region"] })
    }
    fn call(&self, args: &Args) -> Result<ToolOutput, ToolFailure> {
        let (frame, area) = resolve(args, &self.frames)?;
        let target = area.ok_or_else(|| ToolFailure::new("image_crop needs a `region`"))?;
        let pixels = frame.pixels(&target).ok_or_else(|| {
            ToolFailure::new(format!("that region does not overlap frame {}", frame.id))
        })?;
        let base64 = encode_png_base64(&pixels)?;
        let crop = self
            .frames
            .borrow_mut()
            .register_crop(&frame, frame.to_root(&target), pixels);
        Ok(ToolOutput {
            text: format!(
                "frame_id={} — crop of {} at {} ({}x{}).",
                crop.id,
                frame.id,
                crop.origin.json(),
                crop.image.width,
                crop.image.height
            ),
            images: vec![Image {
                base64,
                mime_type: "image/png".into(),
            }],
        })
    }
}

// ============================================================================
// image_diff
// ============================================================================

pub struct ImageDiffTool {
    pub frames: Frames,
}

/// Coarse on purpose: "did something change, and roughly where", not per-pixel
/// truth. A fine grid turns an animated tile into hundreds of hits.
const GRID_COLS: usize = 48;
const GRID_ROWS: usize = 27;

impl Tool for ImageDiffTool {
    fn name(&self) -> String {
        "image_diff".into()
    }
    fn description(&self) -> String {
        "Compare two captured frames and report which areas changed. This is how you check that \
         an action did something: observe, act, observe again, then diff. An empty result means \
         the screen did not react — the tap probably missed. Changed areas come back in \
         whole-frame coordinates."
            .into()
    }
    fn input_schema(&self) -> Value {
        json!({ "type": "object", "properties": {
            "frame_a": { "type": "string", "description": "The earlier frame id." },
            "frame_b": { "type": "string", "description": "The later frame id. Omit for the most recent." },
            "threshold": { "type": "number", "minimum": 0, "maximum": 1,
                           "description": "How different a cell must be to count, 0-1 (default 0.06). Raise it to ignore animation." },
        }, "required": ["frame_a"] })
    }
    fn call(&self, args: &Args) -> Result<ToolOutput, ToolFailure> {
        // Stale-tolerant: before against after is the whole point.
        let store = self.frames.borrow();
        let a_id =
            opt_str(args, "frame_a").ok_or_else(|| ToolFailure::new("missing string `frame_a`"))?;
        let a = store.require(Some(a_id), true)?;
        let b = store.require(opt_str(args, "frame_b"), true)?;
        if a.id == b.id {
            return Err(ToolFailure::new(format!(
                "frame_a and frame_b are the same frame ({})",
                a.id
            )));
        }
        let threshold = args
            .get("threshold")
            .and_then(Value::as_f64)
            .unwrap_or(0.06);
        Ok(ToolOutput::text(diff(&a, &b, threshold).to_string()))
    }
}

fn diff(a: &Frame, b: &Frame, threshold: f64) -> Value {
    let ga = sample(&a.image, GRID_COLS, GRID_ROWS);
    let gb = sample(&b.image, GRID_COLS, GRID_ROWS);
    let mut changed = Vec::new();
    let mut total = 0.0;
    for i in 0..GRID_COLS * GRID_ROWS {
        let d = ((ga[i][0] - gb[i][0]).abs()
            + (ga[i][1] - gb[i][1]).abs()
            + (ga[i][2] - gb[i][2]).abs())
            / 3.0;
        total += d;
        if d > threshold {
            changed.push(i);
        }
    }
    let cells = (GRID_COLS * GRID_ROWS) as f64;
    let r3 = |v: f64| (v * 1000.0).round() / 1000.0;
    if changed.is_empty() {
        return json!({
            "frame_a": a.id, "frame_b": b.id, "changed": false, "changed_fraction": 0,
            "mean_delta": r3(total / cells),
            "note": "Nothing changed above the threshold. If an action should have had an effect, it probably did not land.",
        });
    }
    let boxes = merge(&changed, GRID_COLS, GRID_ROWS);
    json!({
        "frame_a": a.id, "frame_b": b.id, "changed": true,
        "changed_fraction": r3(changed.len() as f64 / cells),
        "mean_delta": r3(total / cells),
        "areas": boxes.iter().map(NormRect::json).collect::<Vec<_>>(),
    })
}

/// Average each grid cell to one RGB triple in 0-1.
fn sample(image: &RawImage, cols: usize, rows: usize) -> Vec<[f64; 3]> {
    let (w, h) = (image.width as usize, image.height as usize);
    let mut out = Vec::with_capacity(cols * rows);
    for r in 0..rows {
        let (y0, y1) = (
            r * h / rows,
            ((r + 1) * h / rows).max(r * h / rows + 1).min(h),
        );
        for c in 0..cols {
            let (x0, x1) = (
                c * w / cols,
                ((c + 1) * w / cols).max(c * w / cols + 1).min(w),
            );
            let mut sum = [0u64; 3];
            let mut n = 0u64;
            for y in y0..y1 {
                for x in x0..x1 {
                    let p = (y * w + x) * 4;
                    for (k, s) in sum.iter_mut().enumerate() {
                        *s += image.rgba[p + k] as u64;
                    }
                    n += 1;
                }
            }
            let n = n.max(1) as f64 * 255.0;
            out.push([sum[0] as f64 / n, sum[1] as f64 / n, sum[2] as f64 / n]);
        }
    }
    out
}

/// Group changed cells into rectangles by 8-connected flood fill, largest first.
fn merge(cells: &[usize], cols: usize, rows: usize) -> Vec<NormRect> {
    let mut remaining: HashSet<usize> = cells.iter().copied().collect();
    let mut boxes = Vec::new();
    let mut seeds: Vec<usize> = cells.to_vec();
    seeds.sort_unstable();
    for seed in seeds {
        if !remaining.remove(&seed) {
            continue;
        }
        let mut stack = vec![seed];
        let (mut min_x, mut max_x, mut min_y, mut max_y) =
            (seed % cols, seed % cols, seed / cols, seed / cols);
        while let Some(cur) = stack.pop() {
            let (x, y) = ((cur % cols) as i64, (cur / cols) as i64);
            min_x = min_x.min(x as usize);
            max_x = max_x.max(x as usize);
            min_y = min_y.min(y as usize);
            max_y = max_y.max(y as usize);
            for dy in -1..=1 {
                for dx in -1..=1 {
                    let (nx, ny) = (x + dx, y + dy);
                    if (dx, dy) == (0, 0)
                        || nx < 0
                        || ny < 0
                        || nx >= cols as i64
                        || ny >= rows as i64
                    {
                        continue;
                    }
                    let n = ny as usize * cols + nx as usize;
                    if remaining.remove(&n) {
                        stack.push(n);
                    }
                }
            }
        }
        boxes.push(NormRect::new(
            min_x as f64 / cols as f64,
            min_y as f64 / rows as f64,
            (max_x + 1) as f64 / cols as f64,
            (max_y + 1) as f64 / rows as f64,
        ));
    }
    boxes.sort_by(|a, b| {
        (b.width() * b.height())
            .partial_cmp(&(a.width() * a.height()))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    boxes
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(image: RawImage, id: &str) -> Frame {
        Frame {
            id: id.into(),
            image: Rc::new(image),
            source: "android".into(),
            observed_epoch: 0,
            origin: NormRect::FULL,
            root_id: id.into(),
        }
    }

    fn solid(w: u32, h: u32, c: [u8; 4]) -> RawImage {
        RawImage {
            width: w,
            height: h,
            rgba: c
                .iter()
                .cycle()
                .take((w * h * 4) as usize)
                .copied()
                .collect(),
        }
    }

    #[test]
    fn identical_frames_do_not_differ() {
        let a = frame(solid(96, 54, [10, 20, 30, 255]), "f1");
        let b = frame(solid(96, 54, [10, 20, 30, 255]), "f2");
        assert_eq!(diff(&a, &b, 0.06)["changed"], false);
    }

    #[test]
    fn a_changed_corner_is_reported_where_it_is() {
        let a = solid(96, 54, [0, 0, 0, 255]);
        let mut b = solid(96, 54, [0, 0, 0, 255]);
        // Paint the bottom-right quarter white.
        for y in 27..54 {
            for x in 48..96 {
                let p = (y * 96 + x) * 4;
                b.rgba[p..p + 3].copy_from_slice(&[255, 255, 255]);
            }
        }
        let v = diff(&frame(a, "f1"), &frame(b, "f2"), 0.06);
        assert_eq!(v["changed"], true);
        let area = &v["areas"][0];
        assert_eq!(area["x1"], 0.5);
        assert_eq!(area["x2"], 1.0);
        assert_eq!(area["y2"], 1.0);
        assert!(area["y1"].as_f64().unwrap() >= 0.48 && area["y1"].as_f64().unwrap() <= 0.52);
    }

    #[test]
    fn separate_changes_stay_separate_and_largest_comes_first() {
        let boxes = merge(&[0, 1, 48, 49, 200], GRID_COLS, GRID_ROWS);
        assert_eq!(boxes.len(), 2);
        assert!(boxes[0].width() * boxes[0].height() > boxes[1].width() * boxes[1].height());
    }
}
