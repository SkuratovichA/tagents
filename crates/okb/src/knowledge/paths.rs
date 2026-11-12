//! Where the documents are, and where the index and the usage store go (`packages/knowledge/src/paths.ts`).
//!
//! okb has a config directory of its own: `OKB_CONFIG_DIR`, else `$XDG_CONFIG_HOME/okb`, else `~/.config/okb`. The folder is `OKB_DIR`, else `TAGENTS_KNOWLEDGE_DIR` (read for one release more), else `dir` in okb's `config.toml`, else `knowledge.dir` in tagents's `config.toml`, which okb only reads. There is no default folder on purpose: guessing one would index whatever happened to be under it. The index and the usage store sit in okb's config directory; a usage store tagents kept is copied there once and left where it was.
//!
//! The environment is a value, not the process: the daemon serves clients whose variables it was started with, and a test sets its own.

use std::{fs, path::Path};

use toml::de::{DeTable, DeValue};

use tagents_core::{
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
    /// `OKB_CONFIG_DIR`: okb's own config directory.
    pub okb_config_dir: Option<String>,
    /// `OKB_DIR`: the folder of the documents.
    pub okb_dir: Option<String>,
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
            okb_config_dir: var("OKB_CONFIG_DIR"),
            okb_dir: var("OKB_DIR"),
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

    /// The directory of tagents's config, where okb looks for a folder and a usage store it did not make itself.
    pub fn tagents_config_dir(&self) -> String {
        config_dir_from(
            self.tagents_config_dir.as_deref(),
            self.xdg_config_home.as_deref(),
            &self.home,
        )
    }

    /// The directory of okb's config: the variable as written, else `okb` under `$XDG_CONFIG_HOME`, else under `~/.config`.
    pub fn config_dir(&self) -> String {
        if let Some(dir) = not_blank(self.okb_config_dir.as_deref()) {
            return dir.to_owned();
        }
        match not_blank(self.xdg_config_home.as_deref()) {
            Some(xdg) => node::join(xdg, "okb"),
            None => node::join(&node::join(&self.home, ".config"), "okb"),
        }
    }

    /// okb's own config file.
    pub fn config_file(&self) -> String {
        node::join(&self.config_dir(), CONFIG_BASENAME)
    }

    /// The file tagents's config is in, read for a folder when okb's own says none.
    pub fn tagents_config_file(&self) -> String {
        node::join(&self.tagents_config_dir(), CONFIG_BASENAME)
    }

    /// The folder `file` names under `section` (`None` is the top level), resolved against the directory of the file. A config that is not there, is not TOML, or has no such string, says nothing.
    fn configured_dir(&self, file: &str, section: Option<&str>) -> Option<String> {
        let text = node::read_utf8(file).ok().flatten()?;
        let root = DeTable::parse(&text).ok()?.into_inner();
        if toml_js::table_holds_lossy_integer(&root) {
            return None;
        }
        let holder = match section {
            None => &root,
            Some(name) => match get(&root, name)? {
                DeValue::Table(table) => table,
                _ => return None,
            },
        };
        let DeValue::String(dir) = get(holder, "dir")? else {
            return None;
        };
        (!dir.is_empty())
            .then(|| self.resolve(&node::dirname(file), Some(&expand_home(dir, &self.home))))
    }

    /// The folder: `OKB_DIR`, else `TAGENTS_KNOWLEDGE_DIR`, else `dir` of okb's config, else `knowledge.dir` of tagents's.
    pub fn resolve_dir(&self) -> DirResult {
        let config = self.config_file();
        let chosen = match not_blank(self.okb_dir.as_deref())
            .or_else(|| not_blank(self.knowledge_dir.as_deref()))
        {
            Some(value) => Some(self.given(value)),
            None => self
                .configured_dir(&config, None)
                .or_else(|| self.configured_dir(&self.tagents_config_file(), Some("knowledge"))),
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

    /// The usage store to read and write: `resolve_usage_db`, and, when that is okb's own default file and it is not there while tagents kept one, a copy of tagents's made first. The old file is only read and stays where it is: it is the only record of what was read. A copy that fails leaves okb with a store of its own that starts empty.
    pub fn usage_file(&self, index_file: &str) -> String {
        let file = self.resolve_usage_db(index_file);
        let own = node::join(&self.config_dir(), USAGE_BASENAME);
        let old = node::join(&self.tagents_config_dir(), USAGE_BASENAME);
        if file == own && !Path::new(&file).exists() && Path::new(&old).is_file() {
            let _ = copy_store(&old, &file);
        }
        file
    }

    /// `resolveUsageDb(null, indexFile, env)`: the variable, else a file of its own beside the index in use, so that a run on a scratch index gets a scratch store and cannot write into the real one.
    pub fn resolve_usage_db(&self, index_file: &str) -> String {
        match not_blank(self.knowledge_usage_db.as_deref()) {
            Some(value) => self.given(value),
            None => node::join(&node::dirname(index_file), USAGE_BASENAME),
        }
    }
}

/// A consistent copy of a store, made by SQLite so that a journal beside it is taken in, written beside the target and renamed into place so a reader never finds half of it.
fn copy_store(from: &str, to: &str) -> Result<(), String> {
    let part = format!("{to}.copying-{}", std::process::id());
    let result = (|| {
        if let Some(parent) = Path::new(to).parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let _ = fs::remove_file(&part);
        let db =
            rusqlite::Connection::open_with_flags(from, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
                .map_err(|e| e.to_string())?;
        db.execute("vacuum into ?1", [&part])
            .map_err(|e| e.to_string())?;
        drop(db);
        fs::rename(&part, to).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&part);
    }
    result
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
    fn okb_config_dir_is_the_variable_then_xdg_then_the_dot_config_of_the_home() {
        let mut env = env();
        assert_eq!(env.config_dir(), "/home/me/.config/okb");
        assert_eq!(env.config_file(), "/home/me/.config/okb/config.toml");
        env.xdg_config_home = Some("/xdg".into());
        assert_eq!(env.config_dir(), "/xdg/okb");
        env.xdg_config_home = Some(" ".into());
        assert_eq!(
            env.config_dir(),
            "/home/me/.config/okb",
            "blank says nothing"
        );
        env.okb_config_dir = Some("rel/cfg".into());
        // The config directory is used as written, not made absolute.
        assert_eq!(env.config_dir(), "rel/cfg");
        // tagents's config is another directory and does not follow okb's.
        env.tagents_config_dir = Some("/tagents/cfg".into());
        assert_eq!(env.tagents_config_file(), "/tagents/cfg/config.toml");
    }

    #[test]
    fn the_defaults_sit_in_okbs_config_directory_and_beside_the_index() {
        let mut env = env();
        assert_eq!(env.resolve_db(), "/home/me/.config/okb/knowledge.sqlite");
        env.xdg_config_home = Some("/xdg".into());
        assert_eq!(env.resolve_db(), "/xdg/okb/knowledge.sqlite");
        env.okb_config_dir = Some("rel/cfg".into());
        assert_eq!(env.resolve_db(), "rel/cfg/knowledge.sqlite");
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
        env.knowledge_db = Some("i.sqlite".into());
        assert_eq!(
            env.resolve_db(),
            "/work/here/i.sqlite",
            "the old variable still works"
        );
    }

    #[test]
    fn no_folder_anywhere_is_unset_and_a_folder_that_is_not_there_is_missing() {
        let mut env = env();
        env.okb_config_dir = Some("/nowhere/cfg".into());
        env.tagents_config_dir = Some("/nowhere/tagents".into());
        assert_eq!(
            env.resolve_dir(),
            DirResult::Unset {
                config: "/nowhere/cfg/config.toml".into()
            }
        );
        env.okb_dir = Some("~/no/such/folder".into());
        assert_eq!(
            env.resolve_dir(),
            DirResult::Missing {
                dir: "/home/me/no/such/folder".into(),
                config: "/nowhere/cfg/config.toml".into()
            }
        );
        env.okb_dir = Some("/".into());
        assert_eq!(env.resolve_dir(), DirResult::Found("/".into()));
    }

    /// A scratch directory of the test with the config files given, `(directory, file text)`.
    fn world(name: &str, files: &[(&str, &str)]) -> (Env, std::path::PathBuf) {
        let root = std::env::temp_dir().join(format!("okb-paths-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for dir in [
            "okb",
            "tagents",
            "docs-env",
            "docs-old-env",
            "docs-okb",
            "docs-tagents",
        ] {
            fs::create_dir_all(root.join(dir)).unwrap();
        }
        for (path, text) in files {
            fs::write(root.join(path), text).unwrap();
        }
        let env = Env {
            home: root.to_string_lossy().into_owned(),
            cwd: root.to_string_lossy().into_owned(),
            okb_config_dir: Some(root.join("okb").to_string_lossy().into_owned()),
            tagents_config_dir: Some(root.join("tagents").to_string_lossy().into_owned()),
            ..Env::default()
        };
        (env, root)
    }

    #[test]
    fn the_folder_is_the_first_of_five_places_that_names_one() {
        let (mut env, root) = world(
            "dir-chain",
            &[
                ("okb/config.toml", "dir = \"../docs-okb\"\n"),
                (
                    "tagents/config.toml",
                    "[knowledge]\ndir = \"../docs-tagents\"\n",
                ),
            ],
        );
        let at = |name: &str| DirResult::Found(root.join(name).to_string_lossy().into_owned());
        // knowledge.dir of tagents's config is the last resort and only read.
        let (tagents_only, _) = world(
            "dir-tagents-only",
            &[(
                "tagents/config.toml",
                "[knowledge]\ndir = \"../docs-tagents\"\n",
            )],
        );
        let root_tagents =
            std::env::temp_dir().join(format!("okb-paths-dir-tagents-only-{}", std::process::id()));
        assert_eq!(
            tagents_only.resolve_dir(),
            DirResult::Found(
                root_tagents
                    .join("docs-tagents")
                    .to_string_lossy()
                    .into_owned()
            )
        );
        // dir of okb's own config beats it.
        assert_eq!(env.resolve_dir(), at("docs-okb"));
        // A variable of the old name beats both files.
        env.knowledge_dir = Some(root.join("docs-old-env").to_string_lossy().into_owned());
        assert_eq!(env.resolve_dir(), at("docs-old-env"));
        // OKB_DIR beats the old variable.
        env.okb_dir = Some(root.join("docs-env").to_string_lossy().into_owned());
        assert_eq!(env.resolve_dir(), at("docs-env"));
        // A blank OKB_DIR says nothing.
        env.okb_dir = Some("  ".into());
        assert_eq!(env.resolve_dir(), at("docs-old-env"));
        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(root_tagents);
    }

    #[test]
    fn a_config_of_okb_without_a_dir_leaves_the_folder_to_the_config_of_tagents() {
        let (env, root) = world(
            "dir-fallthrough",
            &[
                ("okb/config.toml", "other = 1\n"),
                (
                    "tagents/config.toml",
                    "[knowledge]\ndir = \"../docs-tagents\"\n",
                ),
            ],
        );
        assert_eq!(
            env.resolve_dir(),
            DirResult::Found(root.join("docs-tagents").to_string_lossy().into_owned())
        );
        let _ = fs::remove_dir_all(root);
    }

    fn usage_store(path: &std::path::Path, doc: &str) {
        let db = rusqlite::Connection::open(path).unwrap();
        db.execute_batch(&format!(
            "create table seen (doc text); insert into seen values ('{doc}');"
        ))
        .unwrap();
    }

    fn docs_of(path: &std::path::Path) -> Vec<String> {
        let db = rusqlite::Connection::open(path).unwrap();
        let mut statement = db.prepare("select doc from seen").unwrap();
        statement
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    }

    #[test]
    fn the_usage_store_of_tagents_is_copied_once_and_left_where_it_was() {
        let (env, root) = world("usage-copy", &[]);
        let old = root.join("tagents").join(USAGE_BASENAME);
        let own = root.join("okb").join(USAGE_BASENAME);
        usage_store(&old, "from-tagents");
        let before = fs::read(&old).unwrap();
        let index = root.join("okb").join(DB_BASENAME);
        let index = index.to_string_lossy();
        assert_eq!(env.usage_file(&index), own.to_string_lossy());
        assert_eq!(docs_of(&own), ["from-tagents"]);
        assert_eq!(before, fs::read(&old).unwrap(), "the old file is untouched");
        // Once: what okb wrote since is not replaced by a second copy.
        usage_store_add(&own, "written-by-okb");
        env.usage_file(&index);
        assert_eq!(docs_of(&own), ["from-tagents", "written-by-okb"]);
        assert_eq!(before, fs::read(&old).unwrap());
        assert!(
            fs::read_dir(root.join("okb")).unwrap().all(|e| !e
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains("copying"))
        );
        let _ = fs::remove_dir_all(root);
    }

    fn usage_store_add(path: &std::path::Path, doc: &str) {
        let db = rusqlite::Connection::open(path).unwrap();
        db.execute("insert into seen values (?1)", [doc]).unwrap();
    }

    #[test]
    fn nothing_is_copied_when_okb_has_a_store_when_tagents_has_none_or_when_the_store_is_not_okbs_own()
     {
        // okb already has one.
        let (env, root) = world("usage-has", &[]);
        usage_store(&root.join("tagents").join(USAGE_BASENAME), "old");
        usage_store(&root.join("okb").join(USAGE_BASENAME), "new");
        let index = root
            .join("okb")
            .join(DB_BASENAME)
            .to_string_lossy()
            .into_owned();
        env.usage_file(&index);
        assert_eq!(docs_of(&root.join("okb").join(USAGE_BASENAME)), ["new"]);
        let _ = fs::remove_dir_all(&root);
        // tagents has none: no file appears.
        let (env, root) = world("usage-none", &[]);
        let index = root
            .join("okb")
            .join(DB_BASENAME)
            .to_string_lossy()
            .into_owned();
        env.usage_file(&index);
        assert!(!root.join("okb").join(USAGE_BASENAME).exists());
        let _ = fs::remove_dir_all(&root);
        // An index on a scratch path gets a scratch store beside it, and no copy.
        let (env, root) = world("usage-scratch", &[]);
        usage_store(&root.join("tagents").join(USAGE_BASENAME), "old");
        let scratch = root
            .join("docs-env")
            .join(DB_BASENAME)
            .to_string_lossy()
            .into_owned();
        env.usage_file(&scratch);
        assert!(!root.join("docs-env").join(USAGE_BASENAME).exists());
        assert!(!root.join("okb").join(USAGE_BASENAME).exists());
        // The old variable names a store: it is used and nothing is copied.
        let mut env = env;
        env.knowledge_usage_db = Some(root.join("elsewhere.sqlite").to_string_lossy().into_owned());
        assert_eq!(
            env.usage_file(&scratch),
            root.join("elsewhere.sqlite").to_string_lossy()
        );
        assert!(!root.join("elsewhere.sqlite").exists());
        let _ = fs::remove_dir_all(&root);
    }
}
