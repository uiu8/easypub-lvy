//! Media checks operate on snapshot bytes, never on potentially changed source paths.
use serde::Serialize;
use std::collections::BTreeMap;
#[derive(Serialize)]
pub struct Audit {
    pub id: String,
    pub status: &'static str,
    pub media_type: Option<&'static str>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub font: Option<crate::fonts::FontReport>,
}
pub fn apply_permissions(audits: &mut [Audit], permissions: &[String]) {
    for audit in audits {
        if audit.status == "font_permission_required"
            && audit
                .font
                .as_ref()
                .is_some_and(|font| permissions.contains(&font.sha256))
        {
            audit.status = "font_permission_confirmed";
        }
    }
}
pub fn inspect(resources: &BTreeMap<String, Vec<u8>>) -> Vec<Audit> {
    resources
        .iter()
        .map(|(id, bytes)| {
            let extension = id.rsplit('.').next().unwrap_or("");
            let mut audit = Audit {
                id: id.clone(),
                status: "unsupported",
                media_type: None,
                width: None,
                height: None,
                font: None,
            };
            let image = match extension {
                "png" => Some((image::ImageFormat::Png, "image/png")),
                "jpg" | "jpeg" => Some((image::ImageFormat::Jpeg, "image/jpeg")),
                "webp" => Some((image::ImageFormat::WebP, "image/webp")),
                _ => None,
            };
            if let Some((format, mime)) = image {
                match crate::assets::validate_bytes(bytes, format) {
                    Ok((width, height)) => {
                        audit.status = "image_decoded";
                        audit.media_type = Some(mime);
                        audit.width = Some(width);
                        audit.height = Some(height);
                    }
                    Err(_) => audit.status = "invalid_image",
                }
            } else if extension == "woff" {
                audit.media_type = Some("font/woff");
                audit.status = "invalid_font";
                if let Some(decoded) = crate::woff::decode(bytes)
                    && let Ok(mut report) = crate::fonts::inspect_bytes(&decoded, 0, "") {
                        use sha2::Digest;
                        report.sha256 = format!("{:x}", sha2::Sha256::digest(bytes));
                        report.bytes = bytes.len();
                        match crate::woff::license_metadata(bytes) {
                            Ok(Some((text,url))) => {
                                let internal=report.license_text.take().unwrap_or_default();
                                report.license_text=Some(format!("WOFF 扩展许可信息（需自行核对授权）：\n{text}\n\n字体内部许可信息：\n{internal}"));
                                if url.is_some() { report.license_url=url; }
                            }
                            Err(()) => {
                                let internal=report.license_text.take().unwrap_or_default();
                                report.license_text=Some(format!("WOFF 扩展元数据无法有效解析，请核对字体提供方许可。\n\n字体内部许可信息：\n{internal}"));
                            }
                            Ok(None) => {}
                        }
                        audit.status = if report.embedding.outline_allowed {
                            "font_permission_required"
                        } else {
                            "font_embedding_restricted"
                        };
                        audit.font = Some(report);
                    }
            } else if matches!(extension, "ttf" | "otf") {
                let expected = if extension == "otf" {
                    bytes.starts_with(b"OTTO")
                } else {
                    bytes.starts_with(&[0, 1, 0, 0]) || bytes.starts_with(b"true")
                };
                if expected && bytes.len() <= 32 * 1024 * 1024 {
                    match crate::fonts::inspect_bytes(bytes, 0, "") {
                        Ok(report) => {
                            audit.status = if report.embedding.outline_allowed {
                                "font_permission_required"
                            } else {
                                "font_embedding_restricted"
                            };
                            audit.media_type = Some(if extension == "otf" {
                                "font/otf"
                            } else {
                                "font/ttf"
                            });
                            audit.font = Some(report);
                        }
                        Err(_) => audit.status = "invalid_font",
                    }
                } else {
                    audit.status = "invalid_font";
                }
            } else if extension == "css" {
                audit.status = if std::str::from_utf8(bytes).is_ok_and(|css| {
                    !css.contains('\0') && !crate::css_references::inspect(css).incomplete
                }) {
                    "stylesheet_tokens_checked"
                } else {
                    "invalid_stylesheet"
                };
                audit.media_type = Some("text/css");
            }
            audit
        })
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    use image::{DynamicImage, ImageBuffer, ImageFormat, Rgb};
    use std::io::Cursor;
    #[test]
    fn decode_actual_bytes_and_reject_mislabeled_or_truncated_images() {
        for (extension, format) in [
            ("png", ImageFormat::Png),
            ("jpg", ImageFormat::Jpeg),
            ("webp", ImageFormat::WebP),
        ] {
            let image = DynamicImage::ImageRgb8(ImageBuffer::from_pixel(3, 2, Rgb([17, 32, 64])));
            let mut output = Cursor::new(Vec::new());
            image.write_to(&mut output, format).unwrap();
            let bytes = output.into_inner();
            let result = inspect(&BTreeMap::from([(
                format!("sample.{extension}"),
                bytes.clone(),
            )]));
            assert_eq!(result[0].status, "image_decoded");
            assert_eq!((result[0].width, result[0].height), (Some(3), Some(2)));
            let result = inspect(&BTreeMap::from([(
                format!("sample.{extension}"),
                bytes[..bytes.len() / 2].to_vec(),
            )]));
            assert_eq!(result[0].status, "invalid_image");
            if extension != "jpg" {
                assert_eq!(
                    inspect(&BTreeMap::from([("wrong.jpg".into(), bytes)]))[0].status,
                    "invalid_image"
                );
            }
        }
    }
    #[test]
    fn unknown_and_fake_fonts_are_not_ready() {
        let values = BTreeMap::from([
            ("x.ttf".into(), b"fake".to_vec()),
            ("x.svg".into(), b"<svg/>".to_vec()),
        ]);
        let result = inspect(&values);
        assert_eq!(
            result
                .iter()
                .find(|v| v.id.ends_with("ttf"))
                .unwrap()
                .status,
            "invalid_font"
        );
        assert_eq!(
            result
                .iter()
                .find(|v| v.id.ends_with("svg"))
                .unwrap()
                .status,
            "unsupported"
        );
    }
}
