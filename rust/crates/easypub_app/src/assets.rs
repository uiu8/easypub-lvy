//! Decode bounded immutable bytes; fingerprints bind plans to the bytes inspected.
use easypub_core::{ApiError, ErrorCode};
use image::{ImageDecoder, ImageFormat, ImageReader, Limits};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{Cursor, Read},
    path::Path,
};

pub const MAX_IMAGE_BYTES: u64 = 32 * 1024 * 1024;
const MAX_DIMENSION: u32 = 16384;
const MAX_PIXELS: u64 = 16 * 1024 * 1024;
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ImageEvidence {
    pub path: String,
    pub sha256: String,
    pub bytes: u64,
    pub width: u32,
    pub height: u32,
    pub format: String,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "image_resource",
        "choose_readable_supported_image",
    )
}
fn budget() -> ApiError {
    ApiError::new(
        ErrorCode::TooLarge,
        "image_resource",
        "reduce_image_dimensions_or_size",
    )
}
pub struct ImageSnapshot {
    pub evidence: ImageEvidence,
    pub bytes: Vec<u8>,
}
pub fn inspect(value: &str) -> Result<ImageEvidence, ApiError> {
    Ok(snapshot(value)?.evidence)
}
pub fn snapshot(value: &str) -> Result<ImageSnapshot, ApiError> {
    let path = Path::new(value);
    if !path.is_absolute() || value.len() > 32768 {
        return Err(invalid());
    }
    let expected = match path
        .extension()
        .and_then(|v| v.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "png" => ImageFormat::Png,
        "jpg" | "jpeg" => ImageFormat::Jpeg,
        "webp" => ImageFormat::WebP,
        "gif" => ImageFormat::Gif,
        "bmp" => ImageFormat::Bmp,
        _ => return Err(invalid()),
    };
    let file = File::open(path).map_err(|_| invalid())?;
    let meta = file.metadata().map_err(|_| invalid())?;
    if !meta.is_file() || meta.len() == 0 {
        return Err(invalid());
    }
    if meta.len() > MAX_IMAGE_BYTES {
        return Err(budget());
    }
    let mut raw = Vec::new();
    file.take(MAX_IMAGE_BYTES + 1)
        .read_to_end(&mut raw)
        .map_err(|_| invalid())?;
    if raw.len() as u64 > MAX_IMAGE_BYTES {
        return Err(budget());
    }
    let (width, height) = validate_bytes(&raw, expected)?;
    let format = expected;
    let evidence = ImageEvidence {
        path: value.into(),
        sha256: format!("{:x}", Sha256::digest(&raw)),
        bytes: raw.len() as u64,
        width,
        height,
        format: format.extensions_str()[0].into(),
    };
    Ok(ImageSnapshot {
        evidence,
        bytes: raw,
    })
}

/// Shared bounded decoder for disk resources and immutable CSS dependency bytes.
pub(crate) fn validate_bytes(raw: &[u8], expected: ImageFormat) -> Result<(u32, u32), ApiError> {
    if raw.len() as u64 > MAX_IMAGE_BYTES {
        return Err(budget());
    }
    let format = image::guess_format(raw).map_err(|_| invalid())?;
    if format != expected {
        return Err(invalid());
    }
    let make_reader = || {
        let mut reader = ImageReader::with_format(Cursor::new(raw), format);
        let mut limits = Limits::default();
        limits.max_image_width = Some(MAX_DIMENSION);
        limits.max_image_height = Some(MAX_DIMENSION);
        limits.max_alloc = Some(128 * 1024 * 1024);
        reader.limits(limits);
        reader
    };
    let (width, height) = make_reader().into_dimensions().map_err(|_| invalid())?;
    if width == 0 || height == 0 {
        return Err(invalid());
    }
    if width > MAX_DIMENSION
        || height > MAX_DIMENSION
        || u64::from(width) * u64::from(height) > MAX_PIXELS
    {
        return Err(budget());
    }
    // Header recognition is insufficient: consume the complete image decoder.
    let decoded = make_reader().decode().map_err(|_| invalid())?;
    if decoded.width() != width || decoded.height() != height {
        return Err(invalid());
    }
    drop(decoded);
    Ok((width, height))
}

/// Publication bytes use the same visual orientation as the preview. Files that
/// need no transform retain their exact original bytes, all others become PNG.
pub fn display_snapshot(path: &str) -> Result<ImageSnapshot, ApiError> {
    let source = snapshot(path)?;
    let mut decoder = ImageReader::new(Cursor::new(&source.bytes))
        .with_guessed_format()
        .map_err(|_| invalid())?
        .into_decoder()
        .map_err(|_| invalid())?;
    let orientation = decoder.orientation().map_err(|_| invalid())?;
    drop(decoder);
    if orientation == image::metadata::Orientation::NoTransforms {
        return Ok(source);
    }
    cropped(
        &source,
        &Crop {
            x: 0.0,
            y: 0.0,
            width: 1.0,
            height: 1.0,
        },
    )
}

/// Normalized source rectangle; pixel coverage uses floor(left/top), ceil(right/bottom).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Crop {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Crop {
    pub fn validate(&self) -> Result<(), ApiError> {
        if [self.x, self.y, self.width, self.height]
            .iter()
            .any(|v| !v.is_finite())
            || self.x < 0.0
            || self.y < 0.0
            || self.width <= 0.0
            || self.height <= 0.0
            || self.x + self.width > 1.0
            || self.y + self.height > 1.0
        {
            return Err(invalid());
        }
        Ok(())
    }
}
/// Derive a separate immutable PNG; never write to the original file.
pub fn cropped(source: &ImageSnapshot, crop: &Crop) -> Result<ImageSnapshot, ApiError> {
    crop.validate()?;
    let mut reader = ImageReader::new(Cursor::new(&source.bytes))
        .with_guessed_format()
        .map_err(|_| invalid())?;
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_DIMENSION);
    limits.max_image_height = Some(MAX_DIMENSION);
    limits.max_alloc = Some(128 * 1024 * 1024);
    reader.limits(limits);
    let mut decoder = reader.into_decoder().map_err(|_| invalid())?;
    let (width, height) = decoder.dimensions();
    if u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err(budget());
    }
    let orientation = decoder.orientation().map_err(|_| invalid())?;
    let mut decoded = image::DynamicImage::from_decoder(decoder).map_err(|_| invalid())?;
    decoded.apply_orientation(orientation);
    let (w, h) = (decoded.width(), decoded.height());
    if u64::from(w) * u64::from(h) > MAX_PIXELS {
        return Err(budget());
    }
    let x = (crop.x * f64::from(w)).floor() as u32;
    let y = (crop.y * f64::from(h)).floor() as u32;
    let right = ((crop.x + crop.width) * f64::from(w)).ceil() as u32;
    let bottom = ((crop.y + crop.height) * f64::from(h)).ceil() as u32;
    let width = right
        .min(w)
        .checked_sub(x)
        .filter(|v| *v > 0)
        .ok_or_else(invalid)?;
    let height = bottom
        .min(h)
        .checked_sub(y)
        .filter(|v| *v > 0)
        .ok_or_else(invalid)?;
    let cropped = decoded.crop_imm(x, y, width, height);
    let mut output = Cursor::new(Vec::new());
    cropped
        .write_to(&mut output, ImageFormat::Png)
        .map_err(|_| invalid())?;
    let bytes = output.into_inner();
    if bytes.len() as u64 > MAX_IMAGE_BYTES {
        return Err(budget());
    }
    Ok(ImageSnapshot {
        evidence: ImageEvidence {
            path: source.evidence.path.clone(),
            sha256: format!("{:x}", Sha256::digest(&bytes)),
            bytes: bytes.len() as u64,
            width,
            height,
            format: "png".into(),
        },
        bytes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Rgba};
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(1);
    fn path(ext: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "easypub-image-{}-{}.{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
            ext
        ))
    }
    #[test]
    fn decode_and_fingerprint_changes_even_with_same_length() {
        let p = path("png");
        ImageBuffer::from_pixel(2, 2, Rgba([1u8, 2, 3, 255]))
            .save(&p)
            .unwrap();
        let before = inspect(p.to_str().unwrap()).unwrap();
        ImageBuffer::from_pixel(2, 2, Rgba([3u8, 2, 1, 255]))
            .save(&p)
            .unwrap();
        let after = inspect(p.to_str().unwrap()).unwrap();
        assert_eq!(before.bytes, after.bytes);
        assert_ne!(before.sha256, after.sha256);
        assert_eq!((after.width, after.height), (2, 2));
        std::fs::remove_file(p).unwrap();
    }
    #[test]
    fn rejects_fake_truncated_and_wrong_extension() {
        let p = path("png");
        std::fs::write(&p, b"fake PNG").unwrap();
        assert!(inspect(p.to_str().unwrap()).is_err());
        ImageBuffer::from_pixel(2, 2, Rgba([1u8, 2, 3, 255]))
            .save(&p)
            .unwrap();
        let data = std::fs::read(&p).unwrap();
        let wrong = path("jpg");
        std::fs::write(&wrong, &data).unwrap();
        assert!(inspect(wrong.to_str().unwrap()).is_err());
        std::fs::write(&p, &data[..data.len() / 2]).unwrap();
        assert!(inspect(p.to_str().unwrap()).is_err());
        std::fs::remove_file(p).unwrap();
        std::fs::remove_file(wrong).unwrap();
    }
    #[test]
    fn jpeg_and_webp_are_decoded_and_byte_budget_is_enforced() {
        for ext in ["jpg", "webp"] {
            let p = path(ext);
            ImageBuffer::from_pixel(2, 2, image::Rgb([1u8, 2, 3]))
                .save(&p)
                .unwrap();
            let result = inspect(p.to_str().unwrap()).unwrap();
            assert_eq!((result.width, result.height), (2, 2));
            std::fs::remove_file(p).unwrap();
        }
        let p = path("png");
        File::create(&p)
            .unwrap()
            .set_len(MAX_IMAGE_BYTES + 1)
            .unwrap();
        assert_eq!(
            inspect(p.to_str().unwrap()).unwrap_err().code,
            ErrorCode::TooLarge
        );
        std::fs::remove_file(p).unwrap();
    }
    #[test]
    fn total_pixel_budget_is_independent_of_each_dimension() {
        let p = path("png");
        ImageBuffer::from_pixel(4097, 4096, image::Luma([0u8]))
            .save(&p)
            .unwrap();
        assert_eq!(
            inspect(p.to_str().unwrap()).unwrap_err().code,
            ErrorCode::TooLarge
        );
        std::fs::remove_file(p).unwrap();
    }
    #[test]
    fn dimensions_are_rejected_before_pixel_allocation() {
        let p = path("png");
        ImageBuffer::from_pixel(MAX_DIMENSION + 1, 1, Rgba([0u8, 0, 0, 255]))
            .save(&p)
            .unwrap();
        assert!(inspect(p.to_str().unwrap()).is_err());
        std::fs::remove_file(p).unwrap();
    }

    #[test]
    fn real_cmyk_and_transparent_png_decode_and_crop_without_touching_sources() {
        for (ext, bytes) in [
            (
                "jpg",
                include_bytes!("../../../../samples/b7-covers/cmyk.jpg").as_slice(),
            ),
            (
                "png",
                include_bytes!("../../../../samples/b7-covers/transparent.png").as_slice(),
            ),
        ] {
            let p = path(ext);
            std::fs::write(&p, bytes).unwrap();
            let source = snapshot(p.to_str().unwrap()).unwrap();
            assert_eq!((source.evidence.width, source.evidence.height), (16, 12));
            let result = cropped(
                &source,
                &Crop {
                    x: 0.25,
                    y: 0.25,
                    width: 0.5,
                    height: 0.5,
                },
            )
            .unwrap();
            assert_eq!((result.evidence.width, result.evidence.height), (8, 6));
            let image = image::load_from_memory(&result.bytes).unwrap().to_rgba8();
            let pixel = image.get_pixel(0, 0).0;
            if ext == "png" {
                assert_eq!(pixel, [20, 180, 40, 128]);
            } else {
                assert!(pixel[0] > 200 && pixel[1] < 100 && pixel[2] < 100);
                assert_eq!(pixel[3], 255);
            }
            assert_eq!(std::fs::read(&p).unwrap(), bytes);
            std::fs::remove_file(p).unwrap();
        }
    }
}
