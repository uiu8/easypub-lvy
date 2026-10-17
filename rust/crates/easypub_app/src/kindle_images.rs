//! Kindle 可用图片（V24，OUT-078、RES-048）：封面与插图进入制作计划时统一转换，原图不动。
//!
//! · WebP、GIF、BMP 转为 JPEG（不透明）或 PNG（有透明像素）；动图取第一帧；
//! · CMYK 与渐进式 JPEG 重新编码为普通 RGB JPEG；
//! · 超过 2560×1600（长边×短边）的等比缩小；
//! · 已经是普通 PNG / JPEG 且尺寸合适的保留原字节。
//! EPUB 导入时另把 TIFF、SVG 转成 PNG / JPEG 工作副本（[import_ready]），因为界面预览也不能显示它们。
use crate::assets::{ImageEvidence, ImageSnapshot, MAX_IMAGE_BYTES};
use easypub_core::{ApiError, ErrorCode};
use image::{DynamicImage, ImageFormat, ImageReader, Limits, imageops::FilterType};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{io::Cursor, sync::Arc, sync::OnceLock};

/// 长边、短边上限：Kindle 封面建议 1600×2560，插图同样按这个框等比缩小。
pub const MAX_LONG_SIDE: u32 = 2560;
pub const MAX_SHORT_SIDE: u32 = 1600;
const JPEG_QUALITY: u8 = 90;
const MAX_PIXELS: u64 = 16 * 1024 * 1024;

fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "image_resource",
        "choose_readable_supported_image",
    )
}

/// 一次转换的前后对照（写进制作清单，转换前检查据此列出）。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Conversion {
    pub path: String,
    pub from_format: String,
    pub from_width: u32,
    pub from_height: u32,
    pub from_bytes: u64,
    pub to_format: String,
    pub to_width: u32,
    pub to_height: u32,
    pub to_bytes: u64,
    /// format（格式不被 Kindle 支持）、cmyk、progressive、oversize、animation（只取第一帧）。
    pub reasons: Vec<&'static str>,
}

/// JPEG 帧头信息：是否渐进式、颜色分量数。只读标记段，不解码像素。
fn jpeg_frame(bytes: &[u8]) -> Option<(bool, u8)> {
    if bytes.get(..2) != Some(&[0xFF, 0xD8]) {
        return None;
    }
    let mut i = 2;
    while i + 4 <= bytes.len() {
        if bytes[i] != 0xFF {
            return None;
        }
        let marker = bytes[i + 1];
        if marker == 0xFF {
            i += 1;
            continue;
        }
        if matches!(marker, 0xD0..=0xD9 | 0x01) {
            i += 2;
            continue;
        }
        let len = usize::from(u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]));
        // SOF0–SOF15，除去 DHT(C4)、JPG(C8)、DAC(CC)。
        if (0xC0..=0xCF).contains(&marker) && !matches!(marker, 0xC4 | 0xC8 | 0xCC) {
            let components = *bytes.get(i + 9)?;
            let progressive = matches!(marker, 0xC2 | 0xC6 | 0xCA | 0xCE);
            return Some((progressive, components));
        }
        if marker == 0xDA || len < 2 {
            return None;
        }
        i += 2 + len;
    }
    None
}

fn gif_frames(bytes: &[u8]) -> usize {
    use image::AnimationDecoder;
    image::codecs::gif::GifDecoder::new(Cursor::new(bytes))
        .map(|d| d.into_frames().take(2).count())
        .unwrap_or(1)
}

fn target_size(width: u32, height: u32) -> (u32, u32) {
    let (long, short) = (width.max(height), width.min(height));
    if long <= MAX_LONG_SIDE && short <= MAX_SHORT_SIDE {
        return (width, height);
    }
    let scale = (f64::from(MAX_LONG_SIDE) / f64::from(long))
        .min(f64::from(MAX_SHORT_SIDE) / f64::from(short));
    let fit = |v: u32| ((f64::from(v) * scale).round() as u32).max(1);
    (fit(width), fit(height))
}

fn decode(bytes: &[u8]) -> Result<DynamicImage, ApiError> {
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|_| invalid())?;
    let mut limits = Limits::default();
    limits.max_image_width = Some(16384);
    limits.max_image_height = Some(16384);
    limits.max_alloc = Some(256 * 1024 * 1024);
    reader.limits(limits);
    // GIF 解码器的 decode 只取第一帧。
    reader.decode().map_err(|_| invalid())
}

fn has_transparency(image: &DynamicImage) -> bool {
    image.color().has_alpha() && image.to_rgba8().pixels().any(|p| p.0[3] < 255)
}

/// 编码为 Kindle 可用格式：有透明像素或原本就是 PNG（只因尺寸缩小）时用 PNG，其余用 JPEG。
fn encode(image: &DynamicImage, prefer_png: bool) -> Result<(Vec<u8>, &'static str), ApiError> {
    let mut out = Cursor::new(Vec::new());
    if prefer_png || has_transparency(image) {
        image
            .write_to(&mut out, ImageFormat::Png)
            .map_err(|_| invalid())?;
        return Ok((out.into_inner(), "png"));
    }
    let rgb = if image.color().has_color() {
        DynamicImage::ImageRgb8(image.to_rgb8())
    } else {
        DynamicImage::ImageLuma8(image.to_luma8())
    };
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, JPEG_QUALITY)
        .encode_image(&rgb)
        .map_err(|_| invalid())?;
    Ok((out.into_inner(), "jpg"))
}

fn snapshot(path: &str, bytes: Vec<u8>, width: u32, height: u32, format: &str) -> ImageSnapshot {
    ImageSnapshot {
        evidence: ImageEvidence {
            path: path.into(),
            sha256: format!("{:x}", Sha256::digest(&bytes)),
            bytes: bytes.len() as u64,
            width,
            height,
            format: format.into(),
        },
        bytes,
    }
}

/// 封面与插图进入制作计划前的转换；不需要转换时原样返回（同一份字节）。
pub fn kindle_ready(
    source: ImageSnapshot,
) -> Result<(ImageSnapshot, Option<Conversion>), ApiError> {
    let e = &source.evidence;
    let format = e.format.as_str();
    let mut reasons = Vec::new();
    match format {
        "png" => {}
        "jpg" | "jpeg" => {
            if let Some((progressive, components)) = jpeg_frame(&source.bytes) {
                if components == 4 {
                    reasons.push("cmyk");
                }
                if progressive {
                    reasons.push("progressive");
                }
            }
        }
        "gif" => {
            reasons.push("format");
            if gif_frames(&source.bytes) > 1 {
                reasons.push("animation");
            }
        }
        _ => reasons.push("format"),
    }
    let (width, height) = target_size(e.width, e.height);
    if (width, height) != (e.width, e.height) {
        reasons.push("oversize");
    }
    if reasons.is_empty() {
        return Ok((source, None));
    }
    let mut image = decode(&source.bytes)?;
    if (image.width(), image.height()) != (width, height) {
        image = image.resize_exact(width, height, FilterType::Lanczos3);
    }
    let (bytes, to_format) = encode(&image, format == "png")?;
    if bytes.len() as u64 > MAX_IMAGE_BYTES {
        return Err(invalid());
    }
    let result = snapshot(&e.path, bytes, width, height, to_format);
    let conversion = Conversion {
        path: e.path.clone(),
        from_format: format.into(),
        from_width: e.width,
        from_height: e.height,
        from_bytes: e.bytes,
        to_format: to_format.into(),
        to_width: width,
        to_height: height,
        to_bytes: result.evidence.bytes,
        reasons,
    };
    Ok((result, Some(conversion)))
}

fn fonts() -> Arc<resvg::usvg::fontdb::Database> {
    static FONTS: OnceLock<Arc<resvg::usvg::fontdb::Database>> = OnceLock::new();
    FONTS
        .get_or_init(|| {
            let mut db = resvg::usvg::fontdb::Database::new();
            db.load_system_fonts();
            Arc::new(db)
        })
        .clone()
}

/// SVG 栅格化为 PNG：按 viewBox 尺寸，等比放进 2560×1600 的框；过小的放大到长边至少 1200。
pub fn rasterize_svg(data: &[u8]) -> Result<(Vec<u8>, u32, u32), ApiError> {
    let options = resvg::usvg::Options {
        fontdb: fonts(),
        ..Default::default()
    };
    let tree = resvg::usvg::Tree::from_data(data, &options).map_err(|_| invalid())?;
    let size = tree.size();
    let (w, h) = (f64::from(size.width()), f64::from(size.height()));
    if !(w.is_finite() && h.is_finite()) || w <= 0.0 || h <= 0.0 {
        return Err(invalid());
    }
    let (long, short) = (w.max(h), w.min(h));
    let scale = (f64::from(MAX_LONG_SIDE) / long)
        .min(f64::from(MAX_SHORT_SIDE) / short)
        .min((1200.0 / long).max(1.0));
    let width = ((w * scale).round() as u32).max(1);
    let height = ((h * scale).round() as u32).max(1);
    if u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err(invalid());
    }
    let mut pixmap = resvg::tiny_skia::Pixmap::new(width, height).ok_or_else(invalid)?;
    resvg::render(
        &tree,
        resvg::tiny_skia::Transform::from_scale(
            width as f32 / size.width(),
            height as f32 / size.height(),
        ),
        &mut pixmap.as_mut(),
    );
    let png = pixmap.encode_png().map_err(|_| invalid())?;
    Ok((png, width, height))
}

/// 转换后的工作副本：字节、扩展名、媒体类型。
pub type ImportCopy = (Vec<u8>, &'static str, &'static str);

/// EPUB 导入时的图片工作副本：PNG、JPEG、WebP、GIF、BMP 原样保留（界面能预览，输出时再转换）；
/// TIFF 与 SVG 转成 PNG / JPEG。返回 None 表示原样保留；返回 (字节, 扩展名, 媒体类型)。
pub fn import_ready(data: &[u8], media_type: &str) -> Result<Option<ImportCopy>, ApiError> {
    match media_type.to_ascii_lowercase().as_str() {
        "image/svg+xml" => {
            let (png, _, _) = rasterize_svg(data)?;
            Ok(Some((png, "png", "image/png")))
        }
        "image/tiff" | "image/tif" => {
            let image = decode(data)?;
            let (w, h) = target_size(image.width(), image.height());
            let image = if (w, h) != (image.width(), image.height()) {
                image.resize_exact(w, h, FilterType::Lanczos3)
            } else {
                image
            };
            let (bytes, ext) = encode(&image, false)?;
            let media = if ext == "png" {
                "image/png"
            } else {
                "image/jpeg"
            };
            Ok(Some((bytes, ext, media)))
        }
        _ => Ok(None),
    }
}

/// 导入后可直接作为封面或插图的媒体类型（含导入时已转换的 TIFF / SVG 副本）。
pub fn usable_media_type(media_type: &str) -> bool {
    matches!(
        media_type.to_ascii_lowercase().as_str(),
        "image/png" | "image/jpeg" | "image/webp" | "image/gif" | "image/bmp"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Rgb, Rgba};

    fn encoded(image: DynamicImage, format: ImageFormat) -> Vec<u8> {
        let mut out = Cursor::new(Vec::new());
        image.write_to(&mut out, format).unwrap();
        out.into_inner()
    }
    fn snap(bytes: Vec<u8>, format: &str, width: u32, height: u32) -> ImageSnapshot {
        snapshot("C:/图/原图", bytes, width, height, format)
    }
    fn opaque(w: u32, h: u32) -> DynamicImage {
        DynamicImage::ImageRgb8(ImageBuffer::from_fn(w, h, |x, y| {
            Rgb([(x % 256) as u8, (y % 256) as u8, 90])
        }))
    }

    #[test]
    fn plain_png_and_baseline_jpeg_keep_their_exact_bytes() {
        for format in [ImageFormat::Png, ImageFormat::Jpeg] {
            let bytes = encoded(opaque(40, 30), format);
            let name = if format == ImageFormat::Png {
                "png"
            } else {
                "jpg"
            };
            let (out, conversion) = kindle_ready(snap(bytes.clone(), name, 40, 30)).unwrap();
            assert_eq!(out.bytes, bytes);
            assert!(conversion.is_none());
        }
    }

    #[test]
    fn webp_gif_bmp_become_jpeg_or_png_by_transparency() {
        for (format, name) in [
            (ImageFormat::WebP, "webp"),
            (ImageFormat::Gif, "gif"),
            (ImageFormat::Bmp, "bmp"),
        ] {
            let (out, c) =
                kindle_ready(snap(encoded(opaque(20, 10), format), name, 20, 10)).unwrap();
            let c = c.unwrap();
            assert_eq!(
                (c.to_format.as_str(), c.reasons.clone()),
                ("jpg", vec!["format"]),
                "{name}"
            );
            assert_eq!(image::guess_format(&out.bytes).unwrap(), ImageFormat::Jpeg);
            assert_eq!((out.evidence.width, out.evidence.height), (20, 10));
        }
        let clear = DynamicImage::ImageRgba8(ImageBuffer::from_fn(8, 8, |x, _| {
            Rgba([10, 20, 30, if x < 4 { 0 } else { 255 }])
        }));
        let (out, c) = kindle_ready(snap(encoded(clear, ImageFormat::WebP), "webp", 8, 8)).unwrap();
        assert_eq!(c.unwrap().to_format, "png");
        assert_eq!(image::guess_format(&out.bytes).unwrap(), ImageFormat::Png);
    }

    #[test]
    fn animated_gif_keeps_first_frame_and_reports_animation() {
        use image::{Delay, Frame, codecs::gif::GifEncoder};
        let mut bytes = Vec::new();
        {
            let mut encoder = GifEncoder::new(&mut bytes);
            for shade in [10u8, 240] {
                let frame = ImageBuffer::from_pixel(6, 4, Rgba([shade, shade, shade, 255]));
                encoder
                    .encode_frame(Frame::from_parts(
                        frame,
                        0,
                        0,
                        Delay::from_numer_denom_ms(100, 1),
                    ))
                    .unwrap();
            }
        }
        let (out, c) = kindle_ready(snap(bytes, "gif", 6, 4)).unwrap();
        assert_eq!(c.unwrap().reasons, vec!["format", "animation"]);
        let first = image::load_from_memory(&out.bytes).unwrap().to_rgb8();
        assert!(
            first.get_pixel(0, 0).0[0] < 60,
            "取第一帧（深色），不是第二帧"
        );
    }

    #[test]
    fn oversize_is_scaled_into_2560_by_1600_and_png_stays_png() {
        let (out, c) = kindle_ready(snap(
            encoded(opaque(3200, 2000), ImageFormat::Png),
            "png",
            3200,
            2000,
        ))
        .unwrap();
        let c = c.unwrap();
        assert_eq!(c.reasons, vec!["oversize"]);
        assert_eq!(
            (c.to_width, c.to_height, c.to_format.as_str()),
            (2560, 1600, "png")
        );
        assert_eq!((out.evidence.width, out.evidence.height), (2560, 1600));
        // 竖图：短边 1800 > 1600，按短边缩。
        assert_eq!(target_size(1800, 2400), (1600, 2133));
        assert_eq!(target_size(1600, 2560), (1600, 2560));
    }

    #[test]
    fn jpeg_frame_reads_progressive_and_cmyk_markers() {
        let baseline = encoded(opaque(8, 8), ImageFormat::Jpeg);
        assert_eq!(jpeg_frame(&baseline), Some((false, 3)));
        // 手工改帧头：SOF0 → SOF2（渐进式），分量 3 → 4（CMYK）。
        let mut forged = baseline.clone();
        let at = forged.windows(2).position(|w| w == [0xFF, 0xC0]).unwrap();
        forged[at + 1] = 0xC2;
        forged[at + 9] = 4;
        assert_eq!(jpeg_frame(&forged), Some((true, 4)));
        assert_eq!(jpeg_frame(b"not a jpeg"), None);
        // 本机的 image 库只能写普通 JPEG，没有真实的渐进式 / CMYK 样本；这里只验证帧头判定。
    }

    #[test]
    fn svg_and_tiff_import_copies_become_png_or_jpeg() {
        let svg = br##"<svg xmlns="http://www.w3.org/2000/svg" width="300" height="450" viewBox="0 0 300 450"><rect width="300" height="450" fill="#6f6a63"/><circle cx="150" cy="225" r="80" fill="#fff"/></svg>"##;
        let (png, ext, media) = import_ready(svg, "image/svg+xml").unwrap().unwrap();
        assert_eq!((ext, media), ("png", "image/png"));
        let decoded = image::load_from_memory(&png).unwrap();
        // 小图放大到长边 1200，比例不变。
        assert_eq!((decoded.width(), decoded.height()), (800, 1200));
        assert_eq!(decoded.to_rgb8().get_pixel(400, 600).0, [255, 255, 255]);
        let tiff = encoded(opaque(30, 20), ImageFormat::Tiff);
        let (jpg, ext, media) = import_ready(&tiff, "image/tiff").unwrap().unwrap();
        assert_eq!((ext, media), ("jpg", "image/jpeg"));
        assert_eq!(image::guess_format(&jpg).unwrap(), ImageFormat::Jpeg);
        assert!(import_ready(b"x", "image/png").unwrap().is_none());
        assert!(import_ready(b"<svg", "image/svg+xml").is_err());
        assert!(usable_media_type("image/GIF") && !usable_media_type("image/svg+xml"));
    }
}
