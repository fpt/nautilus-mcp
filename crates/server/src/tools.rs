//! The portable tools: the Android primitives (forwarded to `nautilus_core`),
//! the frame tools that work on what they capture, OCR when `tesseract` is
//! installed. `nautilus_status`, which explains anything absent, is the hub's.

use std::cell::RefCell;
use std::collections::HashSet;
use std::io::Write as _;
use std::process::{Command, Stdio};
use std::rc::Rc;

use nautilus_core::image::{decode_png_base64, encode_png, encode_png_base64};
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
    fn run(&self, args: &Args) -> Result<(ToolOutput, Option<Rc<Frame>>), ToolFailure> {
        let output = self.controller.call(
            self.spec.name.clone(),
            Value::Object(args.clone()).to_string(),
        )?;
        if !OBSERVATIONAL.contains(&self.spec.name.as_str()) {
            self.frames.borrow_mut().world_changed();
        }
        let mut text = output.text;
        let mut frame = None;
        if let Some(first) = output.images.first() {
            if let Ok(decoded) = decode_png_base64(&first.base64) {
                let f = self.frames.borrow_mut().register(decoded, "android");
                text.push_str(&format!(
                    " frame_id={} — crop, OCR or diff it without re-capturing.",
                    f.id
                ));
                frame = Some(f);
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
        Ok((ToolOutput { text, images }, frame))
    }
}

/// Shared, so `android_read_text` can capture through the very same tool.
impl Tool for Rc<AndroidTool> {
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
        self.run(args).map(|(out, _)| out)
    }
}

/// Bind a device and wrap every primitive it offers, plus the perception that
/// captures for you. Fails with the reason when no usable device is attached.
pub fn android_tools(
    serial: Option<String>,
    frames: &Frames,
    ocr: Option<Rc<Tesseract>>,
) -> Result<Vec<Box<dyn Tool>>, String> {
    let controller = Rc::new(AndroidController::new(serial).map_err(|e| e.to_string())?);
    let mut tools: Vec<Box<dyn Tool>> = Vec::new();
    let mut observe = None;
    for spec in controller.tools() {
        let schema = serde_json::from_str(&spec.input_schema)
            .unwrap_or_else(|_| json!({ "type": "object", "properties": {} }));
        let tool = Rc::new(AndroidTool {
            controller: controller.clone(),
            spec,
            schema,
            frames: frames.clone(),
        });
        if tool.spec.name == "android_observe" {
            observe = Some(tool.clone());
        }
        tools.push(Box::new(tool));
    }
    if let (Some(observe), Some(ocr)) = (observe, ocr) {
        tools.push(Box::new(AndroidReadTextTool { observe, ocr }));
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

// ============================================================================
// OCR, through the tesseract CLI
// ============================================================================

/// The `tesseract` binary and the language data it has installed.
///
/// Shelling out rather than linking keeps this crate free of native
/// dependencies, exactly as `adb` is used for Android. Absent binary means
/// absent tools — a tool that is listed is a tool that works.
pub struct Tesseract {
    binary: String,
    pub languages: Vec<String>,
}

impl Tesseract {
    pub fn detect() -> Result<Self, String> {
        let binary = std::env::var("TESSERACT")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "tesseract".into());
        let out = Command::new(&binary)
            .arg("--list-langs")
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("`{binary}` not runnable ({e}); install tesseract-ocr"))?;
        if !out.status.success() {
            return Err(format!(
                "`{binary} --list-langs` exited with {}",
                out.status
            ));
        }
        // The listing goes to stdout on 4.x/5.x; some builds print it to stderr.
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        let languages = parse_list_langs(&text);
        if languages.is_empty() {
            return Err(format!("`{binary}` has no language data installed"));
        }
        Ok(Self { binary, languages })
    }

    /// Turn caller hints (`en-US`, `ja`, or tesseract's own `jpn`) into the
    /// installed subset. Falls back to everything useful that is installed.
    fn pick(&self, hints: &[String]) -> (String, Vec<String>) {
        let mut chosen: Vec<String> = Vec::new();
        let mut missing = Vec::new();
        for hint in hints {
            let code = tesseract_code(hint);
            if self.languages.iter().any(|l| l == &code) {
                if !chosen.contains(&code) {
                    chosen.push(code);
                }
            } else {
                missing.push(hint.clone());
            }
        }
        if chosen.is_empty() {
            chosen = self
                .languages
                .iter()
                .filter(|l| l.as_str() != "osd" && l.as_str() != "equ")
                .take(1)
                .cloned()
                .collect();
        }
        (chosen.join("+"), missing)
    }

    /// OCR an image; boxes are local 0-1 to that image.
    fn read(&self, image: &RawImage, languages: &str) -> Result<Vec<OcrLine>, ToolFailure> {
        let png = encode_png(image)?;
        let mut child = Command::new(&self.binary)
            .args(["stdin", "stdout", "-l", languages, "tsv"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| ToolFailure::new(format!("could not start tesseract: {e}")))?;
        let mut stdin = child.stdin.take().expect("piped");
        // Written from a thread so a large image cannot deadlock against a full stdout pipe.
        let writer = std::thread::spawn(move || stdin.write_all(&png));
        let out = child
            .wait_with_output()
            .map_err(|e| ToolFailure::new(format!("tesseract failed: {e}")))?;
        let _ = writer.join();
        if !out.status.success() {
            return Err(ToolFailure::new(format!(
                "tesseract exited with {}: {}",
                out.status,
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(parse_tsv(
            &String::from_utf8_lossy(&out.stdout),
            image.width as f64,
            image.height as f64,
        ))
    }
}

fn parse_list_langs(text: &str) -> Vec<String> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.contains(' ') && !l.ends_with(':'))
        .map(String::from)
        .collect()
}

/// BCP-47-ish hint → tesseract traineddata name. Unknown hints pass through,
/// so a caller can name `chi_sim` or `jpn_vert` directly.
fn tesseract_code(hint: &str) -> String {
    let lower = hint.to_ascii_lowercase();
    let primary = lower.split(['-', '_']).next().unwrap_or("");
    let code = match (primary, lower.as_str()) {
        (_, "zh-hant" | "zh-tw" | "zh-hk") => "chi_tra",
        ("zh", _) => "chi_sim",
        ("en", _) => "eng",
        ("ja", _) => "jpn",
        ("ko", _) => "kor",
        ("fr", _) => "fra",
        ("de", _) => "deu",
        ("es", _) => "spa",
        ("it", _) => "ita",
        ("pt", _) => "por",
        ("ru", _) => "rus",
        _ => return hint.to_string(),
    };
    code.to_string()
}

#[derive(Debug, PartialEq)]
struct OcrLine {
    text: String,
    confidence: f64,
    bbox: NormRect,
}

/// Group tesseract's word rows into lines, with a union box and mean confidence.
fn parse_tsv(tsv: &str, width: f64, height: f64) -> Vec<OcrLine> {
    struct Acc {
        key: (String, String, String, String),
        text: String,
        conf: Vec<f64>,
        x0: f64,
        y0: f64,
        x1: f64,
        y1: f64,
    }
    let mut lines: Vec<Acc> = Vec::new();
    for row in tsv.lines().skip(1) {
        let cols: Vec<&str> = row.split('\t').collect();
        if cols.len() < 12 || cols[0] != "5" {
            continue;
        }
        let word = cols[11].trim();
        let conf: f64 = cols[10].parse().unwrap_or(-1.0);
        if word.is_empty() || conf < 0.0 {
            continue;
        }
        let n = |i: usize| cols[i].parse::<f64>().unwrap_or(0.0);
        let (l, t, w, h) = (n(6), n(7), n(8), n(9));
        let key = (
            cols[1].into(),
            cols[2].into(),
            cols[3].into(),
            cols[4].into(),
        );
        match lines.last_mut() {
            Some(acc) if acc.key == key => {
                // CJK is emitted a glyph per "word"; spaces between them are noise.
                let joins_cjk = acc.text.chars().last().is_some_and(|c| !c.is_ascii())
                    && word.chars().next().is_some_and(|c| !c.is_ascii());
                if !joins_cjk {
                    acc.text.push(' ');
                }
                acc.text.push_str(word);
                acc.conf.push(conf);
                acc.x0 = acc.x0.min(l);
                acc.y0 = acc.y0.min(t);
                acc.x1 = acc.x1.max(l + w);
                acc.y1 = acc.y1.max(t + h);
            }
            _ => lines.push(Acc {
                key,
                text: word.into(),
                conf: vec![conf],
                x0: l,
                y0: t,
                x1: l + w,
                y1: t + h,
            }),
        }
    }
    lines
        .into_iter()
        .map(|a| OcrLine {
            confidence: a.conf.iter().sum::<f64>() / a.conf.len() as f64 / 100.0,
            bbox: NormRect::new(a.x0 / width, a.y0 / height, a.x1 / width, a.y1 / height),
            text: a.text,
        })
        .collect()
}

fn ocr_schema(with_frame: bool) -> Value {
    let mut props = json!({
        "region": NormRect::schema(),
        "languages": { "type": "array", "items": { "type": "string" },
                       "description": "Language hints, e.g. [\"en-US\",\"ja\"]. Default both, as far as tesseract has them installed." },
        "min_confidence": { "type": "number", "minimum": 0, "maximum": 1,
                            "description": "Drop results below this confidence (default 0)." },
    });
    if with_frame {
        props["frame_id"] = frame_id_property();
    }
    json!({ "type": "object", "properties": props })
}

/// Read text in an area of a frame, with every box in root coordinates.
/// Shared by `image_ocr` and `android_read_text` so the two cannot drift.
fn read_text(
    ocr: &Tesseract,
    frame: &Frame,
    area: Option<NormRect>,
    args: &Args,
) -> Result<Value, ToolFailure> {
    let target = area.unwrap_or(NormRect::FULL);
    let pixels = frame.pixels(&target).ok_or_else(|| {
        ToolFailure::new(format!("that region does not overlap frame {}", frame.id))
    })?;
    let hints: Vec<String> = args
        .get("languages")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .filter(|v: &Vec<String>| !v.is_empty())
        .unwrap_or_else(|| vec!["en-US".into(), "ja".into()]);
    let (languages, missing) = ocr.pick(&hints);
    let floor = args
        .get("min_confidence")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);

    let items: Vec<Value> = ocr
        .read(&pixels, &languages)?
        .into_iter()
        .filter(|l| l.confidence >= floor)
        .map(|l| {
            // Local to the cut → through the searched area → through the
            // frame's own placement. The caller only ever sees root coordinates.
            let root = frame.to_root(&target.project(&l.bbox));
            json!({ "text": l.text, "confidence": (l.confidence * 100.0).round() / 100.0, "bbox": root.json() })
        })
        .collect();

    let mut payload = json!({ "frame_id": frame.id, "items": items, "languages": languages });
    if !missing.is_empty() {
        payload["note"] = json!(format!(
            "no tesseract data installed for {}; install e.g. tesseract-ocr-jpn. Installed: {}",
            missing.join(", "),
            ocr.languages.join(", ")
        ));
    } else if payload["items"].as_array().is_some_and(Vec::is_empty) {
        payload["note"] = json!(if area.is_none() {
            "No text found."
        } else {
            "No text found in that region."
        });
    }
    Ok(payload)
}

pub struct ImageOcrTool {
    pub frames: Frames,
    pub ocr: Rc<Tesseract>,
}

impl Tool for ImageOcrTool {
    fn name(&self) -> String {
        "image_ocr".into()
    }
    fn description(&self) -> String {
        "Read the text in a captured frame and return each line with its bounding box. Boxes come \
         back in whole-frame 0.0-1.0 coordinates even when you OCR a sub-region, so a box can be \
         handed straight to android_tap without converting anything. Narrowing to a region is \
         both faster and far more accurate on a busy screen."
            .into()
    }
    fn input_schema(&self) -> Value {
        ocr_schema(true)
    }
    fn call(&self, args: &Args) -> Result<ToolOutput, ToolFailure> {
        let (frame, area) = resolve(args, &self.frames)?;
        Ok(ToolOutput::text(
            read_text(&self.ocr, &frame, area, args)?.to_string(),
        ))
    }
}

/// Capture and OCR in one call, so the answer can never come from a stale frame.
pub struct AndroidReadTextTool {
    observe: Rc<AndroidTool>,
    ocr: Rc<Tesseract>,
}

impl Tool for AndroidReadTextTool {
    fn name(&self) -> String {
        "android_read_text".into()
    }
    fn description(&self) -> String {
        "Read the text currently on the Android screen. Captures a fresh screenshot first, so the \
         result always describes the screen as it is now — prefer this to android_observe \
         followed by image_ocr, which reads whatever was captured last. Boxes come back in \
         whole-frame 0.0-1.0 coordinates, ready for android_tap. Narrow with `region` when you \
         know roughly where to look: it is faster and much more accurate."
            .into()
    }
    fn input_schema(&self) -> Value {
        ocr_schema(false)
    }
    fn call(&self, args: &Args) -> Result<ToolOutput, ToolFailure> {
        let (_, frame) = self.observe.run(&Args::new())?;
        let frame =
            frame.ok_or_else(|| ToolFailure::new("android_observe returned no readable image"))?;
        let area = NormRect::from_json(args.get("region"));
        Ok(ToolOutput::text(
            read_text(&self.ocr, &frame, area, args)?.to_string(),
        ))
    }
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

    /// Real `tesseract … tsv` output shape: level-5 rows are words.
    #[test]
    fn tsv_words_become_lines_in_local_space() {
        let tsv = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n\
                   1\t1\t0\t0\t0\t0\t0\t0\t200\t100\t-1\t\n\
                   4\t1\t1\t1\t1\t0\t10\t10\t90\t20\t-1\t\n\
                   5\t1\t1\t1\t1\t1\t10\t10\t40\t20\t96.5\tSign\n\
                   5\t1\t1\t1\t1\t2\t60\t12\t40\t18\t91.5\tin\n\
                   5\t1\t1\t1\t2\t1\t10\t50\t20\t20\t80\t設\n\
                   5\t1\t1\t1\t2\t2\t30\t50\t20\t20\t90\t定\n\
                   5\t1\t1\t1\t3\t1\t10\t80\t20\t10\t-1\t \n";
        let lines = parse_tsv(tsv, 200.0, 100.0);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].text, "Sign in");
        assert!((lines[0].confidence - 0.94).abs() < 1e-9);
        assert_eq!(lines[0].bbox, NormRect::new(0.05, 0.1, 0.5, 0.3));
        assert_eq!(lines[1].text, "設定");
    }

    #[test]
    fn language_hints_map_to_traineddata_names() {
        assert_eq!(tesseract_code("en-US"), "eng");
        assert_eq!(tesseract_code("ja"), "jpn");
        assert_eq!(tesseract_code("zh-Hant"), "chi_tra");
        assert_eq!(tesseract_code("zh-Hans"), "chi_sim");
        assert_eq!(tesseract_code("jpn_vert"), "jpn_vert");
        let t = Tesseract {
            binary: "x".into(),
            languages: vec!["eng".into(), "osd".into()],
        };
        assert_eq!(
            t.pick(&["en-US".into(), "ja".into()]),
            ("eng".into(), vec!["ja".into()])
        );
        assert_eq!(t.pick(&["ko".into()]).0, "eng");
    }

    #[test]
    fn list_langs_skips_the_header() {
        let out = "List of available languages in \"/usr/share/tesseract-ocr/5/tessdata/\" (3):\neng\njpn\nosd\n";
        assert_eq!(parse_list_langs(out), vec!["eng", "jpn", "osd"]);
    }
}
