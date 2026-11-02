//! Calendar arithmetic in UTC without a calendar crate: `Date.prototype.toISOString` for a millisecond timestamp, and the days between 1970-01-01 and a civil date.

pub const MS_PER_DAY: i64 = 86_400_000;

/// Days since 1970-01-01 to (year, month, day) in the proleptic Gregorian calendar.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * shifted_month + 2) / 5 + 1;
    let month = if shifted_month < 10 {
        shifted_month + 3
    } else {
        shifted_month - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// Days in a month of the proleptic Gregorian calendar.
pub fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Days from 1970-01-01 to a day of the proleptic Gregorian calendar.
pub fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// `new Date(ms).toISOString()`: `2026-01-02T03:04:05.000Z`, and `+275760-09-13T00:00:00.000Z` outside years 0 to 9999.
pub fn iso(ms: i64) -> String {
    let (year, month, day) = civil_from_days(ms.div_euclid(MS_PER_DAY));
    let in_day = ms.rem_euclid(MS_PER_DAY);
    let year = if (0..=9999).contains(&year) {
        format!("{year:04}")
    } else {
        format!("{year:+07}")
    };
    format!(
        "{year}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        in_day / 3_600_000,
        in_day / 60_000 % 60,
        in_day / 1000 % 60,
        in_day % 1000,
    )
}

#[cfg(test)]
mod tests {
    use super::{civil_from_days, days_from_civil, days_in_month, iso};

    #[test]
    fn matches_to_iso_string() {
        assert_eq!(iso(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso(1_767_323_045_000), "2026-01-02T03:04:05.000Z");
        assert_eq!(iso(-1), "1969-12-31T23:59:59.999Z");
        assert_eq!(iso(951_782_400_000), "2000-02-29T00:00:00.000Z");
        assert_eq!(iso(4_107_542_399_999), "2100-02-28T23:59:59.999Z");
        assert_eq!(iso(-62_167_219_200_000), "0000-01-01T00:00:00.000Z");
        assert_eq!(iso(253_402_300_800_000), "+010000-01-01T00:00:00.000Z");
        assert_eq!(iso(-62_198_755_200_000), "-000001-01-01T00:00:00.000Z");
    }

    #[test]
    fn the_two_directions_agree_on_every_day_of_two_millennia() {
        for days in -800_000..800_000 {
            let (year, month, day) = civil_from_days(days);
            assert!(
                (1..=12).contains(&month) && (1..=days_in_month(year, month)).contains(&day),
                "{days} gave {year}-{month}-{day}"
            );
            assert_eq!(
                days_from_civil(year, month, day),
                days,
                "{year}-{month}-{day}"
            );
        }
    }

    #[test]
    fn leap_years_follow_the_gregorian_rule() {
        let february = |year| days_in_month(year, 2);
        assert_eq!(
            [
                february(1900),
                february(2000),
                february(2024),
                february(2100)
            ],
            [28, 29, 29, 28]
        );
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(
            days_from_civil(2000, 3, 1) - days_from_civil(2000, 2, 28),
            2
        );
    }
}
