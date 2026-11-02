//! What the CLI reads of the host it runs on, as `packages/core/src/host.ts` does: where the configuration directory is, and the config file in it.
//!
//! The twin lives here and not in a feature (`notify` re-exports the directory) because every verb that reads the config needs the same answer.

use crate::{js, node};

/// The config file's name inside the config directory (`CONFIG_BASENAME` of `packages/core/src/host.ts`).
const CONFIG_BASENAME: &str = "config.toml";

/// `configFile()` of `packages/core/src/host.ts`.
pub fn config_file() -> String {
    node::join(&config_dir(), CONFIG_BASENAME)
}

/// `configDir` of `packages/core/src/host.ts`: `$TAGENTS_CONFIG_DIR` unless blank, else `$XDG_CONFIG_HOME` unless blank, else `~/.config`, then `tagents`.
pub fn config_dir() -> String {
    let env = |name: &str| std::env::var_os(name).map(|v| v.to_string_lossy().into_owned());
    config_dir_from(
        env("TAGENTS_CONFIG_DIR").as_deref(),
        env("XDG_CONFIG_HOME").as_deref(),
        &node::homedir(),
    )
}

/// `config_dir` with the two variables and the home directory given, `None` for an unset variable. A variable that is blank by `String.prototype.trim` (empty, or only JavaScript whitespace, U+FEFF included) is as good as unset, and `$TAGENTS_CONFIG_DIR` is used as written, not trimmed.
pub fn config_dir_from(
    tagents_config_dir: Option<&str>,
    xdg_config_home: Option<&str>,
    home: &str,
) -> String {
    if let Some(dir) = not_blank(tagents_config_dir) {
        return dir.to_owned();
    }
    let base = match not_blank(xdg_config_home) {
        Some(xdg) => xdg.to_owned(),
        None => node::join(home, ".config"),
    };
    node::join(&base, "tagents")
}

/// An environment variable that is set and not blank: JavaScript's `value && value.trim()`.
fn not_blank(value: Option<&str>) -> Option<&str> {
    value.filter(|v| !js::trim(v).is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_dir_follows_the_rules_of_host_ts() {
        for (dir, xdg, want) in [
            (Some("/c"), None, "/c"),
            (Some(" /c "), None, " /c "),
            (Some(""), None, "/h/.config/tagents"),
            (Some("  \t"), None, "/h/.config/tagents"),
            (Some("\u{feff}"), Some("/x"), "/x/tagents"),
            (Some("\u{a0}\u{2028}"), None, "/h/.config/tagents"),
            (Some("\u{200b}"), None, "\u{200b}"),
            (None, Some("/x"), "/x/tagents"),
            (None, Some("/x/../y/"), "/y/tagents"),
            (None, Some(" "), "/h/.config/tagents"),
            (None, Some(""), "/h/.config/tagents"),
            (None, None, "/h/.config/tagents"),
            (Some("/c"), Some("/x"), "/c"),
            (Some(" "), Some("/x"), "/x/tagents"),
        ] {
            assert_eq!(config_dir_from(dir, xdg, "/h"), want, "{dir:?} {xdg:?}");
        }
    }
}
