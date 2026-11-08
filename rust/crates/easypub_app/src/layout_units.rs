//! Author lengths retain their units until a rendering context is available.
pub fn em() -> String {
    "em".into()
}
pub fn number() -> String {
    "number".into()
}
pub fn valid_unit(unit: &str) -> bool {
    matches!(unit, "px" | "pt" | "em" | "%")
}
pub fn valid_font(value: f64, unit: &str, modern: bool) -> bool {
    if !modern {
        return match unit {
            "%" => (50.0..=200.0).contains(&value),
            "px" => (14.0..=26.0).contains(&value),
            _ => false,
        };
    }
    valid_unit(unit) && value.is_finite() && (8.0..=200.0).contains(&font_px(value, unit))
}
pub fn valid_line(value: f64, unit: &str, modern: bool) -> bool {
    if !modern {
        unit == "number" && (1.0..=2.3).contains(&value)
    } else {
        valid(value, unit, true)
    }
}
pub fn valid(value: f64, unit: &str, line: bool) -> bool {
    value.is_finite()
        && value >= if line { 0.1 } else { 0.0 }
        && match unit {
            "number" if line => value <= 6.0,
            "em" => value <= 20.0,
            "%" => value <= 1000.0,
            "px" | "pt" => value <= 1000.0,
            _ => false,
        }
}
pub fn css(value: f64, unit: &str) -> String {
    match unit {
        "pt" => format!("{}px", value * 96.0 / 72.0),
        "number" => value.to_string(),
        _ => format!("{value}{unit}"),
    }
}
pub fn font_px(value: f64, unit: &str) -> f64 {
    match unit {
        "%" => 16.0 * value / 100.0,
        "em" => value * 16.0,
        "pt" => value * 4.0 / 3.0,
        _ => value,
    }
}
