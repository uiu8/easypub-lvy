use easypub_app::assets::{self, Crop};
use image::{ImageBuffer, ImageEncoder, Rgb};
use serde_json::json;
use std::{fs, path::PathBuf};
fn main() {
    let dir = PathBuf::from("artifacts/r5-orientation");
    fs::create_dir_all(&dir).unwrap();
    let pixels = ImageBuffer::from_fn(48, 32, |x, y| {
        Rgb([
            if x < 24 { 30u8 } else { 190 },
            if y < 16 { 50 } else { 210 },
            80,
        ])
    });
    let crop = Crop {
        x: 0.125,
        y: 0.25,
        width: 0.5,
        height: 0.5,
    };
    let mut cases = Vec::new();
    for format in ["jpg", "png", "webp"] {
        for orientation in 1u8..=8 {
            // Little-endian TIFF IFD with one SHORT Orientation tag, no other metadata.
            let mut exif = vec![
                b'I',
                b'I',
                42,
                0,
                8,
                0,
                0,
                0,
                1,
                0,
                0x12,
                1,
                3,
                0,
                1,
                0,
                0,
                0,
                orientation,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            ];
            if format == "png" && orientation == 6 {
                exif.splice(8..8, std::iter::repeat_n(0u8, 128 * 1024));
                exif[4..8].copy_from_slice(&(8u32 + 128 * 1024).to_le_bytes());
            }
            let mut bytes = Vec::new();
            match format {
                "jpg" => {
                    let mut e = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 98);
                    e.set_exif_metadata(exif).unwrap();
                    e.write_image(pixels.as_raw(), 48, 32, image::ExtendedColorType::Rgb8)
                        .unwrap();
                }
                "png" => {
                    let mut e = image::codecs::png::PngEncoder::new(&mut bytes);
                    e.set_exif_metadata(exif).unwrap();
                    e.write_image(pixels.as_raw(), 48, 32, image::ExtendedColorType::Rgb8)
                        .unwrap();
                }
                "webp" => {
                    let mut e = image::codecs::webp::WebPEncoder::new_lossless(&mut bytes);
                    e.set_exif_metadata(exif).unwrap();
                    e.write_image(pixels.as_raw(), 48, 32, image::ExtendedColorType::Rgb8)
                        .unwrap();
                }
                _ => unreachable!(),
            }
            let path = dir.join(format!("orientation-{orientation}.{format}"));
            fs::write(&path, &bytes).unwrap();
            let source = assets::snapshot(path.canonicalize().unwrap().to_str().unwrap()).unwrap();
            let display =
                assets::display_snapshot(path.canonicalize().unwrap().to_str().unwrap()).unwrap();
            let display_path = dir.join(format!(
                "display-{format}-{orientation}.{}",
                display.evidence.format
            ));
            fs::write(&display_path, display.bytes).unwrap();
            let output = assets::cropped(&source, &crop).unwrap();
            let output_path = dir.join(format!("crop-{format}-{orientation}.png"));
            fs::write(&output_path, output.bytes).unwrap();
            cases.push(json!({"display":display_path.file_name().unwrap().to_str().unwrap(),"format":format,"orientation":orientation,"source":path.file_name().unwrap().to_str().unwrap(),"crop":output_path.file_name().unwrap().to_str().unwrap()}));
        }
    }
    fs::write(
        dir.join("cases.json"),
        serde_json::to_vec_pretty(&json!({"rect":crop,"cases":cases})).unwrap(),
    )
    .unwrap();
    println!("Generated {} cross-engine cases", cases.len());
}
