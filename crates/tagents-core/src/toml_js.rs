//! The TOML of the node CLI is smol-toml's, and the `toml` crate reads the same language with two differences that change what a program may do with a file: an integer beyond the safe range of a JavaScript number is an error to smol-toml and a value to the crate, and node holds integers and floats as numbers where the crate holds the text the file wrote.
//! The rules below turn the crate's tree into what the node parser would have made of it. `notify::options` reads the daemon's options file with them and `plugin::config` edits the plugin list with them.

use toml::de::{DeFloat, DeInteger, DeTable, DeValue};

/// The value under `key` of a table, as the key is written.
pub fn get<'a, 'i>(table: &'a DeTable<'i>, key: &str) -> Option<&'a DeValue<'i>> {
    table
        .iter()
        .find(|(name, _)| name.get_ref().as_ref() == key)
        .map(|(_, value)| value.get_ref())
}

/// The largest integer a JavaScript number holds exactly, `Number.MAX_SAFE_INTEGER`.
pub const MAX_SAFE_INTEGER: i128 = 9_007_199_254_740_991;
/// The text node's TOML parser gives for an integer it cannot hold: it refuses it, and so does this reader.
pub const LOSSY_INTEGER: &str = "integer value cannot be represented losslessly";

/// An integer anywhere in the document that a JavaScript number cannot hold exactly: the node parser refuses the whole file for it, whatever key it is under.
pub fn table_holds_lossy_integer(table: &DeTable<'_>) -> bool {
    table
        .values()
        .any(|value| holds_lossy_integer(value.get_ref()))
}

fn holds_lossy_integer(value: &DeValue<'_>) -> bool {
    match value {
        DeValue::Integer(int) => integer(int).is_none(),
        DeValue::Array(items) => items.iter().any(|item| holds_lossy_integer(item.get_ref())),
        DeValue::Table(table) => table_holds_lossy_integer(table),
        _ => false,
    }
}

/// An integer as a JavaScript number, or `None` when it is not a safe integer (`Number.isSafeInteger`).
pub fn integer(int: &DeInteger<'_>) -> Option<f64> {
    let value = i128::from_str_radix(int.as_str(), int.radix()).ok()?;
    (value.abs() <= MAX_SAFE_INTEGER).then_some(value as f64)
}

/// A float as `parseFloat` of its text gives it: an overflow is infinity, `nan` and `inf` are the special values.
pub fn float(f: &DeFloat<'_>) -> f64 {
    let text = f.as_str().replace('_', "");
    match text.trim_start_matches(['+', '-']) {
        "inf" => {
            if text.starts_with('-') {
                f64::NEG_INFINITY
            } else {
                f64::INFINITY
            }
        }
        "nan" => f64::NAN,
        _ => text.parse().unwrap_or(f64::NAN),
    }
}
