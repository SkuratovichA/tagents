//! The pieces of JavaScript string and number semantics the `sessions` text depends on.
//!
//! The node CLI builds its text with `trim`, `/\s+/`, `slice`, `padEnd`, `toLowerCase`, `Number` and `Math.round`.
//! Each of them differs from the nearest Rust method in a way that changes bytes on stdout, so each is spelled out here once and pinned by `tests/rust-parity.sh`.
//! A JavaScript string is a sequence of UTF-16 code units; a Rust `String` cannot hold a lone surrogate.
//! Where JavaScript would end up with one (a `slice` that cuts a surrogate pair), the text is written to stdout as U+FFFD, so that is what is produced here, and nothing downstream of these helpers can tell.

/// What `/\s/` and `String.prototype.trim` treat as white space.
/// It is the ECMAScript WhiteSpace and LineTerminator sets, which differ from `char::is_whitespace`: U+FEFF counts, U+0085 does not.
pub fn is_space(c: char) -> bool {
    matches!(
        c,
        '\u{9}'..='\u{d}'
            | ' '
            | '\u{a0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200a}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202f}'
            | '\u{205f}'
            | '\u{3000}'
            | '\u{feff}'
    )
}

/// `s.trim()`.
pub fn trim(s: &str) -> &str {
    s.trim_matches(is_space)
}

/// `s.replace(/\s+/g, ' ')`.
pub fn collapse_space(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_run = false;
    for c in s.chars() {
        if is_space(c) {
            if !in_run {
                out.push(' ');
            }
            in_run = true;
        } else {
            out.push(c);
            in_run = false;
        }
    }
    out
}

/// `s.split(/\s+/)`: a run of white space is one separator, and one at either end leaves an empty piece.
pub fn split_space(s: &str) -> Vec<&str> {
    let mut pieces = Vec::new();
    let mut start = 0;
    let mut chars = s.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        if !is_space(c) {
            continue;
        }
        let mut end = i + c.len_utf8();
        while let Some(&(j, next)) = chars.peek() {
            if !is_space(next) {
                break;
            }
            end = j + next.len_utf8();
            chars.next();
        }
        pieces.push(&s[start..i]);
        start = end;
    }
    pieces.push(&s[start..]);
    pieces
}

/// The length of `s` in UTF-16 code units, which is what `.length` counts.
pub fn len16(s: &str) -> usize {
    s.chars().map(char::len_utf16).sum()
}

/// `s.slice(0, n)`.
/// A cut between the two halves of a surrogate pair leaves the high half alone, which stdout writes as U+FFFD.
pub fn take16(s: &str, n: usize) -> String {
    let mut out = String::new();
    let mut used = 0;
    for c in s.chars() {
        let width = c.len_utf16();
        if used + width > n {
            if used < n {
                out.push('\u{fffd}');
            }
            break;
        }
        out.push(c);
        used += width;
    }
    out
}

/// `s.padEnd(n)`.
pub fn pad_end(s: &str, n: usize) -> String {
    let mut out = s.to_owned();
    out.extend(std::iter::repeat_n(' ', n.saturating_sub(len16(s))));
    out
}

/// `s.toLowerCase()`: the Unicode default case mapping, final sigma included, in the root locale.
pub fn lower(s: &str) -> String {
    s.to_lowercase()
}

/// `Number(s)` for a string: `StringToNumber`.
/// Rust's own float parser also takes `inf`, `nan` and `infinity` in any case, which `Number` does not, so the grammar is checked first.
pub fn number(s: &str) -> f64 {
    let s = trim(s);
    if s.is_empty() {
        return 0.0;
    }
    match s {
        "Infinity" | "+Infinity" => return f64::INFINITY,
        "-Infinity" => return f64::NEG_INFINITY,
        _ => {}
    }
    if let Some(digits) = s.strip_prefix('0') {
        let radix = match digits.chars().next() {
            Some('x' | 'X') => Some(16),
            Some('o' | 'O') => Some(8),
            Some('b' | 'B') => Some(2),
            _ => None,
        };
        if let Some(radix) = radix {
            return radix_number(&digits[1..], radix);
        }
    }
    if is_decimal_literal(s) {
        s.parse().unwrap_or(f64::NAN)
    } else {
        f64::NAN
    }
}

/// `0x…`, `0o…`, `0b…` without a sign. Past 128 bits the value only has to stay huge: every use here clamps it to a count of rows.
fn radix_number(digits: &str, radix: u32) -> f64 {
    if digits.is_empty() {
        return f64::NAN;
    }
    let mut value: u128 = 0;
    for c in digits.chars() {
        let Some(d) = c.to_digit(radix) else {
            return f64::NAN;
        };
        value = value
            .saturating_mul(u128::from(radix))
            .saturating_add(u128::from(d));
    }
    value as f64
}

/// `[+-]? (digits [. digits?]? | . digits) ([eE] [+-]? digits)?`
fn is_decimal_literal(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = usize::from(matches!(b.first(), Some(b'+' | b'-')));
    let int_start = i;
    while b.get(i).is_some_and(u8::is_ascii_digit) {
        i += 1;
    }
    let int_digits = i - int_start;
    let mut frac_digits = 0;
    if b.get(i) == Some(&b'.') {
        i += 1;
        let frac_start = i;
        while b.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        frac_digits = i - frac_start;
    }
    if int_digits == 0 && frac_digits == 0 {
        return false;
    }
    if matches!(b.get(i), Some(b'e' | b'E')) {
        i += 1;
        if matches!(b.get(i), Some(b'+' | b'-')) {
            i += 1;
        }
        let exp_start = i;
        while b.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        if i == exp_start {
            return false;
        }
    }
    i == b.len()
}

/// `Math.round(x)`: halves go up, also below zero, where `f64::round` sends them away from zero.
pub fn round(x: f64) -> f64 {
    let floor = x.floor();
    if x - floor >= 0.5 { floor + 1.0 } else { floor }
}

/// How many items `list.slice(0, count)` keeps, for `count` as `Number` gave it.
/// `ToIntegerOrInfinity` truncates toward zero, and a negative end counts from the back.
pub fn slice_end(count: f64, len: usize) -> usize {
    let whole = count.trunc();
    let len = len as f64;
    let end = if whole < 0.0 {
        (len + whole).max(0.0)
    } else {
        whole.min(len)
    };
    end as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn white_space_is_the_ecmascript_set() {
        assert!(is_space('\u{feff}') && is_space('\u{a0}') && is_space('\u{2028}'));
        assert!(!is_space('\u{85}') && !is_space('\u{180e}') && !is_space('\u{200b}'));
        assert_eq!(trim("\u{feff} \u{3000}x\u{a0}\n"), "x");
        assert_eq!(trim("\u{85}x"), "\u{85}x");
    }

    #[test]
    fn runs_of_white_space_collapse_to_one_space() {
        assert_eq!(collapse_space("a \n\t b\u{3000}\u{3000}c "), "a b c ");
        assert_eq!(collapse_space(""), "");
    }

    #[test]
    fn split_matches_the_regex_split() {
        assert_eq!(split_space(""), [""]);
        assert_eq!(split_space("a  b"), ["a", "b"]);
        assert_eq!(split_space(" a"), ["", "a"]);
        assert_eq!(split_space("a "), ["a", ""]);
        assert_eq!(split_space("  "), ["", ""]);
        assert_eq!(split_space("a\u{a0}\u{2003}b c"), ["a", "b", "c"]);
    }

    #[test]
    fn lengths_count_utf16_units() {
        assert_eq!(len16("Привет"), 6);
        assert_eq!(len16("a😀"), 3);
        assert_eq!(take16("a😀b", 2), "a\u{fffd}");
        assert_eq!(take16("a😀b", 3), "a😀");
        assert_eq!(take16("a😀b", 4), "a😀b");
        assert_eq!(take16("abc", 10), "abc");
        assert_eq!(pad_end("😀", 4), "😀  ");
        assert_eq!(pad_end("long", 2), "long");
    }

    #[test]
    fn lower_cases_like_the_root_locale() {
        assert_eq!(lower("ΟΔΟΣ ΑΣ"), "οδος ας");
        assert_eq!(lower("İ"), "i\u{307}");
    }

    #[test]
    fn numbers_follow_string_to_number() {
        for (text, want) in [
            ("", 0.0),
            ("  12  ", 12.0),
            ("\u{a0}7\u{2028}", 7.0),
            ("007", 7.0),
            ("1.", 1.0),
            (".5", 0.5),
            ("+.5e1", 5.0),
            ("1e3", 1000.0),
            ("0x1F", 31.0),
            ("0B101", 5.0),
            ("0o17", 15.0),
            ("-3", -3.0),
            ("Infinity", f64::INFINITY),
            ("-Infinity", f64::NEG_INFINITY),
            ("1e999", f64::INFINITY),
        ] {
            assert_eq!(number(text), want, "{text:?}");
        }
        for text in [
            ".",
            "+",
            "e5",
            "1e",
            "1e+",
            "inf",
            "nan",
            "NaN",
            "infinity",
            "Infinity1",
            "1_0",
            "0x",
            "-0x10",
            "+0b1",
            "1 2",
            "10n",
            "٣",
            "0xg",
            "1.5.2",
            "--1",
        ] {
            assert!(number(text).is_nan(), "{text:?}");
        }
    }

    #[test]
    fn rounding_and_slicing() {
        assert_eq!(round(0.5), 1.0);
        assert_eq!(round(-0.5), 0.0);
        assert_eq!(round(-2.5), -2.0);
        assert_eq!(round(0.499_999_999_999_999_94), 0.0);
        assert_eq!(slice_end(2.7, 5), 2);
        assert_eq!(slice_end(0.5, 5), 0);
        assert_eq!(slice_end(-0.5, 5), 0);
        assert_eq!(slice_end(-1.0, 5), 4);
        assert_eq!(slice_end(-9.0, 5), 0);
        assert_eq!(slice_end(f64::INFINITY, 5), 5);
        assert_eq!(slice_end(f64::NEG_INFINITY, 5), 0);
        assert_eq!(slice_end(1e300, 5), 5);
    }
}
