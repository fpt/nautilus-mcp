//! Image payloads, and the PNG codec the Swift side borrows.
//!
//! # Why PNG coding lives in Rust
//!
//! Swift has ImageIO, and using it would be the obvious choice. On the
//! development machine ImageIO's codecs fault — SIGBUS, `EXC_ARM_DA_ALIGN`,
//! jumping to a poisoned `0xbad4007` function pointer — in *any* ordinary
//! compiled binary, for encode and decode, PNG and TIFF alike. Apple-signed
//! hosts (the `swift` interpreter, `xctest`) are unaffected, which is exactly
//! why a unit test cannot catch it. A reboot did not help, nor did re-signing
//! with a hardened runtime.
//!
//! Everything else Swift needs still works: building a `CGImage` from raw bytes
//! is CoreGraphics, and Vision reads such an image happily. Only the file codec
//! is unusable. So the bytes come through here instead, on the pure-Rust `png`
//! crate, and Swift never opens an image file.

use base64::Engine as _;

use crate::NautilusError;

/// An image a tool produced, base64-encoded with its media type.
#[derive(Debug, Clone)]
pub struct ImageContent {
    pub base64: String,
    /// e.g. `image/png`, `image/jpeg`.
    pub media_type: String,
}

/// Uncompressed pixels, row-major RGBA8.
///
/// The shape `CGImage` can be built from directly, so Swift needs no decoder.
pub struct RawImage {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Largest image we will decode, as a guard against a corrupt header claiming
/// enormous dimensions: 64 megapixels is far beyond any screen we drive.
const MAX_PIXELS: u64 = 64 * 1024 * 1024;

/// Decode a base64 PNG into RGBA8.
///
/// Handles whatever the source produced — palette, grayscale, RGB, 16-bit —
/// by asking the decoder to expand to 8-bit channels first, then widening RGB
/// to RGBA. Android's `screencap -p` emits RGBA8 already; the rest is for
/// anything else that ends up here.
pub fn decode_png_base64(base64_png: &str) -> Result<RawImage, NautilusError> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(base64_png.trim())
        .map_err(|e| NautilusError::ConfigError(format!("not valid base64: {e}")))?;
    decode_png(&bytes)
}

pub fn decode_png(bytes: &[u8]) -> Result<RawImage, NautilusError> {
    let mut decoder = png::Decoder::new(bytes);
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);

    let mut reader = decoder
        .read_info()
        .map_err(|e| NautilusError::ConfigError(format!("not a readable PNG: {e}")))?;
    let info = reader.info();
    let (width, height) = (info.width, info.height);

    if u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err(NautilusError::ConfigError(format!(
            "refusing to decode a {width}x{height} image"
        )));
    }

    let mut buffer = vec![0u8; reader.output_buffer_size()];
    let frame = reader
        .next_frame(&mut buffer)
        .map_err(|e| NautilusError::InternalError(format!("PNG decode failed: {e}")))?;
    buffer.truncate(frame.buffer_size());

    let pixels = (width as usize) * (height as usize);
    let rgba = match frame.color_type {
        png::ColorType::Rgba => buffer,
        png::ColorType::Rgb => widen(&buffer, pixels, 3, |px, out| {
            out.extend_from_slice(px);
            out.push(255);
        }),
        png::ColorType::Grayscale => widen(&buffer, pixels, 1, |px, out| {
            out.extend_from_slice(&[px[0], px[0], px[0], 255]);
        }),
        png::ColorType::GrayscaleAlpha => widen(&buffer, pixels, 2, |px, out| {
            out.extend_from_slice(&[px[0], px[0], px[0], px[1]]);
        }),
        // EXPAND turns a palette into RGB/RGBA, so this should be unreachable.
        other => {
            return Err(NautilusError::InternalError(format!(
                "unsupported PNG colour type {other:?}"
            )))
        }
    };

    Ok(RawImage {
        width,
        height,
        rgba,
    })
}

/// Expand `stride`-byte pixels to RGBA8.
fn widen(
    source: &[u8],
    pixels: usize,
    stride: usize,
    mut write: impl FnMut(&[u8], &mut Vec<u8>),
) -> Vec<u8> {
    let mut out = Vec::with_capacity(pixels * 4);
    for pixel in source.chunks_exact(stride).take(pixels) {
        write(pixel, &mut out);
    }
    out
}

/// Encode RGBA8 pixels as a base64 PNG, ready for an MCP image block.
pub fn encode_png_base64(image: &RawImage) -> Result<String, NautilusError> {
    Ok(base64::engine::general_purpose::STANDARD.encode(encode_png(image)?))
}

pub fn encode_png(image: &RawImage) -> Result<Vec<u8>, NautilusError> {
    let expected = (image.width as usize)
        .saturating_mul(image.height as usize)
        .saturating_mul(4);
    if image.width == 0 || image.height == 0 {
        return Err(NautilusError::ConfigError("image has no area".to_string()));
    }
    if image.rgba.len() != expected {
        return Err(NautilusError::ConfigError(format!(
            "expected {expected} bytes of RGBA for {}x{}, got {}",
            image.width,
            image.height,
            image.rgba.len()
        )));
    }

    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, image.width, image.height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder
            .write_header()
            .map_err(|e| NautilusError::InternalError(format!("PNG header failed: {e}")))?;
        writer
            .write_image_data(&image.rgba)
            .map_err(|e| NautilusError::InternalError(format!("PNG write failed: {e}")))?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(width: u32, height: u32, colour: [u8; 4]) -> RawImage {
        RawImage {
            width,
            height,
            rgba: colour
                .iter()
                .cycle()
                .take((width * height * 4) as usize)
                .copied()
                .collect(),
        }
    }

    #[test]
    fn round_trips_pixels_unchanged() {
        let original = solid(7, 5, [10, 20, 30, 255]);
        let decoded = decode_png_base64(&encode_png_base64(&original).unwrap()).unwrap();
        assert_eq!((decoded.width, decoded.height), (7, 5));
        assert_eq!(decoded.rgba, original.rgba);
    }

    /// A real screenshot is opaque RGB; it must come back with alpha added
    /// rather than as a short buffer that would shear every row.
    #[test]
    fn rgb_is_widened_to_rgba() {
        let mut png_bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut png_bytes, 2, 1);
            encoder.set_color(png::ColorType::Rgb);
            encoder.set_depth(png::BitDepth::Eight);
            let mut writer = encoder.write_header().unwrap();
            writer.write_image_data(&[1, 2, 3, 4, 5, 6]).unwrap();
        }
        let decoded = decode_png(&png_bytes).unwrap();
        assert_eq!(decoded.rgba, vec![1, 2, 3, 255, 4, 5, 6, 255]);
    }

    #[test]
    fn grayscale_is_widened_to_rgba() {
        let mut png_bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut png_bytes, 2, 1);
            encoder.set_color(png::ColorType::Grayscale);
            encoder.set_depth(png::BitDepth::Eight);
            let mut writer = encoder.write_header().unwrap();
            writer.write_image_data(&[9, 200]).unwrap();
        }
        let decoded = decode_png(&png_bytes).unwrap();
        assert_eq!(decoded.rgba, vec![9, 9, 9, 255, 200, 200, 200, 255]);
    }

    /// Rubbish must be an error, never a panic across the FFI boundary.
    #[test]
    fn rubbish_is_rejected() {
        assert!(decode_png_base64("not base64 !!!").is_err());
        assert!(decode_png_base64("").is_err());
        assert!(decode_png(b"nowhere near a PNG").is_err());
    }

    #[test]
    fn a_buffer_of_the_wrong_size_is_refused() {
        let bad = RawImage {
            width: 4,
            height: 4,
            rgba: vec![0; 10],
        };
        assert!(encode_png(&bad).is_err());
        assert!(encode_png(&solid(0, 4, [0, 0, 0, 0])).is_err());
    }
}
