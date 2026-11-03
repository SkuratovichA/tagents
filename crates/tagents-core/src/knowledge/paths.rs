//! Where the documents are, and where the index and the usage store go (`packages/knowledge/src/paths.ts`).
//!
//! Two answers, each from the environment and then, for the folder, from the machine's config. There is no default folder on purpose: guessing one would index whatever happened to be under it. The index and the store have defaults beside the config.
//!
//! The environment is a value, not the process: the daemon serves clients whose variables it was started with, and a test sets its own.

use std::path::Path;

use toml::de::{DeTable, DeValue};

use crate::{
    host::{config_dir_from, not_blank},
    node,
    toml_js::{self, get},
};

pub const DB_BASENAME: &str = "knowledge.sqlite";
/// What was read, kept apart from the index: the index is derived and rebuilt, this is not.
pub const USAGE_BASENAME: &str = "knowledge-usage.sqlite";
const CONFIG_BASENAME: &str = "config.toml";

/// The variables the answers depend on, as node reads them from `process.env`, the directory its `path.resolve` starts from, and the variables the socket of the shared server is named from. `None` is a variable that is not set.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Env {
    /// `os.homedir()`.
    pub home: String,
    /// `process.env.HOME` itself, which `os.homedir()` falls back from: the key of the shared server reads the variable and not the answer.
    pub home_var: Option<String>,
    /// `process.cwd()`.
    pub cwd: String,
    pub tagents_config_dir: Option<String>,
    pub xdg_config_home: Option<String>,
    pub knowledge_dir: Option<String>,
    pub knowledge_db: Option<String>,
    pub knowledge_usage_db: Option<String>,
    /// Read by the sessions tools, which list transcripts and know nothing of the paths above.
    pub claude_homes: Option<String>,
    /// The three variables `os.tmpdir()` reads, in the order it reads them: the socket's directory is under the first that is set.
    pub tmpdir: Option<String>,
    pub tmp: Option<String>,
    pub temp: Option<String>,
}

/// Where the folder is, or why nobody can say.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DirResult {
    Found(String),
    /// Nobody said where.
    Unset {
        config: String,
    },
    /// Somebody did, and it is not there.
    Missing {
        dir: String,
        config: String,
    },
}

/// `~/x` is `<home>/x`: a config file written by a human has tildes.
pub fn expand_home(p: &str, home: &str) -> String {
    if p == "~" {
        return home.to_owned();
    }
    match p.strip_prefix("~/") {
        Some(rest) => node::join(home, rest),
        None => p.to_owned(),
    }
}

impl Env {
    /// The process's own: the variables the paths read, the home directory and the working directory.
    pub fn from_process() -> Env {
        let cwd = std::env::current_dir()
            .map(|dir| dir.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "/".to_owned());
        Env::from_vars(node::homedir(), cwd, node::env_text)
    }

    /// The variables of any source: the process, a test's table, a client's request.
    pub fn from_vars(home: String, cwd: String, var: impl Fn(&str) -> Option<String>) -> Env {
        Env {
            home,
            home_var: var("HOME"),
            cwd,
            tagents_config_dir: var("TAGENTS_CONFIG_DIR"),
            xdg_config_home: var("XDG_CONFIG_HOME"),
            knowledge_dir: var("TAGENTS_KNOWLEDGE_DIR"),
            knowledge_db: var("TAGENTS_KNOWLEDGE_DB"),
            knowledge_usage_db: var("TAGENTS_KNOWLEDGE_USAGE_DB"),
            claude_homes: var("CLAUDE_HOMES"),
            tmpdir: var("TMPDIR"),
            tmp: var("TMP"),
            temp: var("TEMP"),
        }
    }

    /// `path.resolve(...paths)` of one or two paths: the last absolute one, and what follows it, below the working directory when none is.
    fn resolve(&self, first: &str, then: Option<&str>) -> String {
        let base = node::resolve(&self.cwd, first);
        then.map_or(base.clone(), |then| node::resolve(&base, then))
    }

    /// `path.resolve(expandHome(value))`.
    fn given(&self, value: &str) -> String {
        self.resolve(&expand_home(value, &self.home), None)
    }

    /// The directory of the config: `configDir(env)`.
    pub fn config_dir(&self) -> String {
        config_dir_from(
            self.tagents_config_dir.as_deref(),
            self.xdg_config_home.as_deref(),
            &self.home,
        )
    }

    /// `configFile(env)`.
    pub fn config_file(&self) -> String {
        node::join(&self.config_dir(), CONFIG_BASENAME)
    }

    /// `knowledge.dir` of the config, resolved against the directory of the config file. A config that is not there, is not TOML, or has no such string, says nothing.
    fn configured_dir(&self, file: &str) -> Option<String> {
        let text = node::read_utf8(file).ok().flatten()?;
        let root = DeTable::parse(&text).ok()?.into_inner();
        if toml_js::table_holds_lossy_integer(&root) {
            return None;
        }
        let DeValue::Table(section) = get(&root, "knowledge")? else {
            return None;
        };
        let DeValue::String(dir) = get(section, "dir")? else {
            return None;
        };
        (!dir.is_empty())
            .then(|| self.resolve(&node::dirname(file), Some(&expand_home(dir, &self.home))))
    }

    /// `resolveDir(null, env)`: the variable, else the config.
    pub fn resolve_dir(&self) -> DirResult {
        let config = self.config_file();
        let chosen = match not_blank(self.knowledge_dir.as_deref()) {
            Some(value) => Some(self.given(value)),
            None => self.configured_dir(&config),
        };
        match chosen {
            None => DirResult::Unset { config },
            Some(dir) if !Path::new(&dir).exists() => DirResult::Missing { dir, config },
            Some(dir) => DirResult::Found(dir),
        }
    }

    /// `resolveDb(null, env)`: the variable, else a file of its own in the config directory.
    pub fn resolve_db(&self) -> String {
        match not_blank(self.knowledge_db.as_deref()) {
            Some(value) => self.given(value),
            None => node::join(&self.config_dir(), DB_BASENAME),
        }
    }

    /// `resolveUsageDb(null, indexFile, env)`: the variable, else a file of its own beside the index in use, so that a run on a scratch index gets a scratch store and cannot write into the real one.
    pub fn resolve_usage_db(&self, index_file: &str) -> String {
        match not_blank(self.knowledge_usage_db.as_deref()) {
            Some(value) => self.given(value),
            None => node::join(&node::dirname(index_file), USAGE_BASENAME),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env() -> Env {
        Env {
            home: "/home/me".into(),
            cwd: "/work/here".into(),
            ..Env::default()
        }
    }

    #[test]
    fn a_tilde_is_the_home_directory_and_nothing_else_is() {
        for (given, want) in [
            ("~", "/home/me"),
            ("~/docs", "/home/me/docs"),
            ("~/a/../b", "/home/me/b"),
            ("~me/docs", "~me/docs"),
            ("docs/~", "docs/~"),
            ("", ""),
        ] {
            assert_eq!(expand_home(given, "/home/me"), want, "{given}");
        }
    }

    #[test]
    fn a_given_path_is_made_absolute_against_the_working_directory() {
        let env = env();
        assert_eq!(env.given("docs"), "/work/here/docs");
        assert_eq!(env.given("../docs/"), "/work/docs");
        assert_eq!(env.given("~/docs"), "/home/me/docs");
        assert_eq!(env.given("/abs//x"), "/abs/x");
    }

    #[test]
    fn the_defaults_sit_in_the_config_directory_and_beside_the_index() {
        let mut env = env();
        assert_eq!(
            env.resolve_db(),
            "/home/me/.config/tagents/knowledge.sqlite"
        );
        env.xdg_config_home = Some("/xdg".into());
        assert_eq!(env.resolve_db(), "/xdg/tagents/knowledge.sqlite");
        env.tagents_config_dir = Some("rel/cfg".into());
        // The config directory is used as written, not made absolute.
        assert_eq!(env.resolve_db(), "rel/cfg/knowledge.sqlite");
        assert_eq!(env.config_file(), "rel/cfg/config.toml");
        assert_eq!(
            env.resolve_usage_db("/some/where/index.sqlite"),
            "/some/where/knowledge-usage.sqlite"
        );
        env.knowledge_usage_db = Some(" ".into());
        assert_eq!(
            env.resolve_usage_db("index.sqlite"),
            "knowledge-usage.sqlite",
            "a blank variable says nothing"
        );
        env.knowledge_usage_db = Some("u.sqlite".into());
        assert_eq!(
            env.resolve_usage_db("/x/index.sqlite"),
            "/work/here/u.sqlite"
        );
    }

    #[test]
    fn no_folder_anywhere_is_unset_and_a_folder_that_is_not_there_is_missing() {
        let mut env = env();
        env.tagents_config_dir = Some("/nowhere/cfg".into());
        assert_eq!(
            env.resolve_dir(),
            DirResult::Unset {
                config: "/nowhere/cfg/config.toml".into()
            }
        );
        env.knowledge_dir = Some("~/no/such/folder".into());
        assert_eq!(
            env.resolve_dir(),
            DirResult::Missing {
                dir: "/home/me/no/such/folder".into(),
                config: "/nowhere/cfg/config.toml".into()
            }
        );
        env.knowledge_dir = Some("/".into());
        assert_eq!(env.resolve_dir(), DirResult::Found("/".into()));
    }
}
