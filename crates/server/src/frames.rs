//! Frames, regions and the interaction epoch — the Rust port of the Swift
//! `FrameStore`, with the same invariants:
//!
//! - **Every box is in root-frame coordinates.** A crop remembers where it sits
//!   in the frame it was cut from, so anything found inside it projects back.
//! - **Observations have a lifetime.** Every device action bumps the epoch, and
//!   reading a frame captured before it is refused with a machine-readable
//!   `stale_frame` explanation.
//! - **An omitted `frame_id` means the latest capture**, never the last crop.

use std::rc::Rc;

use nautilus_core::RawImage;
use serde_json::{json, Value};

use crate::mcp::ToolFailure;

/// A rectangle in root-frame normalized coordinates, top-left origin.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NormRect {
    pub x1: f64,
    pub y1: f64,
    pub x2: f64,
    pub y2: f64,
}

impl NormRect {
    pub const FULL: NormRect = NormRect {
        x1: 0.0,
        y1: 0.0,
        x2: 1.0,
        y2: 1.0,
    };

    /// Either corner order means the same region, never an empty one.
    pub fn new(x1: f64, y1: f64, x2: f64, y2: f64) -> Self {
        Self {
            x1: x1.min(x2),
            y1: y1.min(y2),
            x2: x1.max(x2),
            y2: y1.max(y2),
        }
    }

    pub fn width(&self) -> f64 {
        self.x2 - self.x1
    }
    pub fn height(&self) -> f64 {
        self.y2 - self.y1
    }
    pub fn is_empty(&self) -> bool {
        self.width() <= 0.0 || self.height() <= 0.0
    }

    pub fn clamped(&self) -> Self {
        let c = |v: f64| v.clamp(0.0, 1.0);
        Self::new(c(self.x1), c(self.y1), c(self.x2), c(self.y2))
    }

    /// Map a rect in this rect's local 0-1 space into the space this rect lives in.
    pub fn project(&self, local: &NormRect) -> NormRect {
        NormRect::new(
            self.x1 + local.x1 * self.width(),
            self.y1 + local.y1 * self.height(),
            self.x1 + local.x2 * self.width(),
            self.y1 + local.y2 * self.height(),
        )
    }

    /// The inverse of [`project`](Self::project). `None` when this rect has no area.
    pub fn localize(&self, outer: &NormRect) -> Option<NormRect> {
        if self.width() <= 0.0 || self.height() <= 0.0 {
            return None;
        }
        Some(NormRect::new(
            (outer.x1 - self.x1) / self.width(),
            (outer.y1 - self.y1) / self.height(),
            (outer.x2 - self.x1) / self.width(),
            (outer.y2 - self.y1) / self.height(),
        ))
    }

    /// Rounded to four places: a screen is not addressable to fifteen, and the
    /// noise is pure token cost.
    pub fn json(&self) -> Value {
        let r = |v: f64| (v * 10000.0).round() / 10000.0;
        json!({ "x1": r(self.x1), "y1": r(self.y1), "x2": r(self.x2), "y2": r(self.y2) })
    }

    /// Parse `{x1,y1,x2,y2}`, or the `{x,y,w,h}` spelling.
    pub fn from_json(value: Option<&Value>) -> Option<NormRect> {
        let o = value?.as_object()?;
        let n = |k: &str| o.get(k).and_then(Value::as_f64);
        if let (Some(x1), Some(y1), Some(x2), Some(y2)) = (n("x1"), n("y1"), n("x2"), n("y2")) {
            return Some(NormRect::new(x1, y1, x2, y2));
        }
        if let (Some(x), Some(y), Some(w), Some(h)) = (n("x"), n("y"), n("w"), n("h")) {
            return Some(NormRect::new(x, y, x + w, y + h));
        }
        None
    }

    pub fn schema() -> Value {
        let edge =
            |d: &str| json!({ "type": "number", "minimum": 0, "maximum": 1, "description": d });
        json!({
            "type": "object",
            "description": "A rectangle in frame-normalized 0.0-1.0 coordinates, top-left origin. \
                            Always relative to the whole original frame, never to a crop.",
            "properties": {
                "x1": edge("Left edge."), "y1": edge("Top edge."),
                "x2": edge("Right edge."), "y2": edge("Bottom edge."),
            },
            "required": ["x1", "y1", "x2", "y2"],
        })
    }
}

/// One captured image, addressable by id. A crop is also a frame.
pub struct Frame {
    pub id: String,
    pub image: Rc<RawImage>,
    /// Where the image came from, e.g. `android`.
    pub source: String,
    /// The interaction epoch at capture time.
    pub observed_epoch: u64,
    /// Placement within the root frame, in root coordinates. `FULL` for a capture.
    pub origin: NormRect,
    /// The capture this descends from — itself, if captured.
    pub root_id: String,
}

impl Frame {
    pub fn is_crop(&self) -> bool {
        self.origin != NormRect::FULL
    }

    pub fn to_root(&self, local: &NormRect) -> NormRect {
        self.origin.project(local)
    }

    pub fn to_local(&self, root: &NormRect) -> Option<NormRect> {
        self.origin.localize(root)
    }

    /// Cut a root-coordinate rect out as pixels. `None` when it misses this image.
    pub fn pixels(&self, root: &NormRect) -> Option<RawImage> {
        let local = self.to_local(root)?.clamped();
        if local.is_empty() {
            return None;
        }
        let (w, h) = (self.image.width as f64, self.image.height as f64);
        let x0 = ((local.x1 * w).floor() as u32).min(self.image.width - 1);
        let y0 = ((local.y1 * h).floor() as u32).min(self.image.height - 1);
        let cw = ((local.width() * w).round().max(1.0) as u32).min(self.image.width - x0);
        let ch = ((local.height() * h).round().max(1.0) as u32).min(self.image.height - y0);
        Some(crop(&self.image, x0, y0, cw, ch))
    }
}

pub fn crop(image: &RawImage, x0: u32, y0: u32, w: u32, h: u32) -> RawImage {
    let stride = image.width as usize * 4;
    let mut rgba = Vec::with_capacity(w as usize * h as usize * 4);
    for row in y0..y0 + h {
        let start = row as usize * stride + x0 as usize * 4;
        rgba.extend_from_slice(&image.rgba[start..start + w as usize * 4]);
    }
    RawImage {
        width: w,
        height: h,
        rgba,
    }
}

/// The last few frames, plus the epoch that decides whether one is still true.
pub struct FrameStore {
    frames: Vec<Rc<Frame>>,
    next_number: u64,
    capacity: usize,
    epoch: u64,
}

impl Default for FrameStore {
    fn default() -> Self {
        Self::new(8)
    }
}

impl FrameStore {
    pub fn new(capacity: usize) -> Self {
        Self {
            frames: Vec::new(),
            next_number: 1,
            capacity: capacity.max(1),
            epoch: 0,
        }
    }

    /// The world may have moved on — called for every device action, `wait` included.
    pub fn world_changed(&mut self) {
        self.epoch = self.epoch.wrapping_add(1);
    }

    pub fn register(&mut self, image: RawImage, source: &str) -> Rc<Frame> {
        let id = self.next_id();
        let frame = Rc::new(Frame {
            root_id: id.clone(),
            id,
            image: Rc::new(image),
            source: source.to_string(),
            observed_epoch: self.epoch,
            origin: NormRect::FULL,
        });
        self.append(frame.clone());
        frame
    }

    /// A crop is exactly as current as the frame it came out of.
    pub fn register_crop(&mut self, parent: &Frame, root: NormRect, image: RawImage) -> Rc<Frame> {
        let frame = Rc::new(Frame {
            id: self.next_id(),
            image: Rc::new(image),
            source: parent.source.clone(),
            observed_epoch: parent.observed_epoch,
            origin: root,
            root_id: parent.root_id.clone(),
        });
        self.append(frame.clone());
        frame
    }

    /// `None`/empty means the latest capture — never a crop.
    pub fn frame(&self, id: Option<&str>) -> Option<Rc<Frame>> {
        match id {
            None | Some("") => self.frames.iter().rev().find(|f| !f.is_crop()).cloned(),
            Some(id) => self.frames.iter().find(|f| f.id == id).cloned(),
        }
    }

    /// Resolve a frame or explain why not. Refuses a stale frame unless `allow_stale`.
    pub fn require(&self, id: Option<&str>, allow_stale: bool) -> Result<Rc<Frame>, ToolFailure> {
        let Some(frame) = self.frame(id) else {
            if self.frames.is_empty() {
                return Err(ToolFailure::new(
                    "no frames captured yet — call android_observe first",
                ));
            }
            let ids: Vec<&str> = self.frames.iter().map(|f| f.id.as_str()).collect();
            return Err(ToolFailure::new(format!(
                "no frame {}; the store holds {} (only the last {} are kept)",
                id.unwrap_or("?"),
                ids.join(", "),
                self.capacity
            )));
        };
        if !allow_stale && frame.observed_epoch < self.epoch {
            return Err(ToolFailure::new(self.stale_message(&frame)));
        }
        Ok(frame)
    }

    fn stale_message(&self, frame: &Frame) -> String {
        json!({
            "error": "stale_frame",
            "frame_id": frame.id,
            "captured_epoch": frame.observed_epoch,
            "current_epoch": self.epoch,
            "actions_since": self.epoch - frame.observed_epoch,
            "recovery": "The screen has been acted on since this frame was captured, so anything \
                         read from it describes a world that no longer exists. Capture again with \
                         android_observe, or use a tool that captures for you (android_read_text).",
        })
        .to_string()
    }

    fn append(&mut self, frame: Rc<Frame>) {
        self.frames.push(frame);
        if self.frames.len() > self.capacity {
            let excess = self.frames.len() - self.capacity;
            self.frames.drain(..excess);
        }
    }

    fn next_id(&mut self) -> String {
        let id = format!("f{}", self.next_number);
        self.next_number += 1;
        id
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub fn solid(w: u32, h: u32, c: [u8; 4]) -> RawImage {
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
    fn a_crop_of_a_crop_reports_root_coordinates() {
        let mut store = FrameStore::default();
        let root = store.register(solid(100, 100, [0, 0, 0, 255]), "android");
        let right_half = NormRect::new(0.5, 0.0, 1.0, 1.0);
        let c1 = store.register_crop(&root, right_half, root.pixels(&right_half).unwrap());
        assert_eq!((c1.image.width, c1.image.height), (50, 100));
        // The bottom half of the crop, in crop-local space…
        let local = NormRect::new(0.0, 0.5, 1.0, 1.0);
        // …is the bottom-right quarter of the screen.
        assert_eq!(c1.to_root(&local), NormRect::new(0.5, 0.5, 1.0, 1.0));
    }

    #[test]
    fn omitted_id_means_the_latest_capture_not_the_latest_crop() {
        let mut store = FrameStore::default();
        let root = store.register(solid(10, 10, [0, 0, 0, 255]), "android");
        let r = NormRect::new(0.0, 0.0, 0.5, 0.5);
        store.register_crop(&root, r, root.pixels(&r).unwrap());
        assert_eq!(store.frame(None).unwrap().id, root.id);
    }

    #[test]
    fn a_frame_from_before_an_action_is_refused() {
        let mut store = FrameStore::default();
        let f = store.register(solid(4, 4, [0, 0, 0, 255]), "android");
        store.world_changed();
        let err = store.require(Some(&f.id), false).err().unwrap();
        let v: Value = serde_json::from_str(&err.message).unwrap();
        assert_eq!(v["error"], "stale_frame");
        assert_eq!(v["actions_since"], 1);
        assert!(store.require(Some(&f.id), true).is_ok());
    }

    #[test]
    fn evicted_frames_are_named_as_missing() {
        let mut store = FrameStore::new(2);
        for _ in 0..3 {
            store.register(solid(2, 2, [0, 0, 0, 255]), "android");
        }
        let err = store.require(Some("f1"), false).err().unwrap();
        assert!(err.message.contains("f2, f3"), "{}", err.message);
    }

    #[test]
    fn a_region_off_the_image_has_no_pixels() {
        let mut store = FrameStore::default();
        let root = store.register(solid(10, 10, [0, 0, 0, 255]), "android");
        let r = NormRect::new(0.0, 0.0, 0.5, 0.5);
        let crop = store.register_crop(&root, r, root.pixels(&r).unwrap());
        assert!(crop.pixels(&NormRect::new(0.6, 0.6, 0.9, 0.9)).is_none());
    }
}
