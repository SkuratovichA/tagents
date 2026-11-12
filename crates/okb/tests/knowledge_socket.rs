//! Where the shared server of one environment listens: the directory, the key that names the socket, and the rules of the directory's owner and mode, against what the node server (`packages/knowledge/src/mcp/socket.ts`) makes of the same environments.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::{
    collections::HashMap,
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    path::Path,
    time::{Duration, SystemTime},
};

use okb::knowledge::{
    doc::hash_of,
    paths::Env,
    socket::{
        KEY_VARS, canonical, code_stamp, ensure_private_dir, exported, key_lines, lock_dir_of,
        pid_file_of, program_stamp, server_key, socket_dir, socket_path,
    },
};
use rustix::process::geteuid;
use serde_json::Value;

use common::{knowledge::vectors, scratch};

fn uid() -> u32 {
    geteuid().as_raw()
}

/// The environment of a case of the vectors, read as the process's own is: through the one constructor.
fn env_of(case: &Value) -> Env {
    let vars: HashMap<&str, &str> = case["env"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(name, value)| (name.as_str(), value.as_str().unwrap()))
        .collect();
    let var = |name: &str| vars.get(name).map(|value| (*value).to_owned());
    Env::from_vars(
        var("HOME").unwrap_or_default(),
        case["cwd"].as_str().unwrap().to_owned(),
        var,
    )
}

fn socket_cases() -> Vec<&'static Value> {
    let socket = &vectors()["process"]["socket"];
    ["tmp", "key"]
        .into_iter()
        .flat_map(|section| socket[section].as_array().unwrap())
        .collect()
}

#[test]
fn the_directory_of_every_environment_is_the_one_node_chose() {
    let cases = vectors()["process"]["socket"]["tmp"].as_array().unwrap();
    for case in cases {
        let want = case["dir"]
            .as_str()
            .unwrap()
            .replace("UID", &uid().to_string());
        assert_eq!(want, socket_dir(&env_of(case), uid()), "{}", case["name"]);
    }
    // A table that lost its cases proves nothing.
    assert!(cases.len() >= 25, "{} cases", cases.len());
}

#[test]
fn the_variables_and_the_key_of_every_environment_are_the_recorded_ones() {
    let cases = socket_cases();
    for case in &cases {
        let env = env_of(case);
        let want: Vec<&str> = case["lines"]
            .as_array()
            .unwrap()
            .iter()
            .map(|line| line.as_str().unwrap())
            .collect();
        assert_eq!(want, key_lines(&env), "{}", case["name"]);
        assert_eq!(
            case["key"].as_str().unwrap(),
            server_key(
                &env,
                vectors()["process"]["socket"]["stamp"].as_str().unwrap()
            ),
            "{}",
            case["name"]
        );
    }
    assert!(cases.len() >= 35, "{} cases", cases.len());
}

#[test]
fn the_key_variables_are_the_six_names_of_the_node_program_without_the_claude_homes() {
    assert_eq!(
        [
            "HOME",
            "TAGENTS_CONFIG_DIR",
            "XDG_CONFIG_HOME",
            "TAGENTS_KNOWLEDGE_DIR",
            "TAGENTS_KNOWLEDGE_DB",
            "TAGENTS_KNOWLEDGE_USAGE_DB"
        ],
        KEY_VARS
    );
}

fn base() -> Env {
    Env {
        home: "/home/u".into(),
        home_var: Some("/home/u".into()),
        cwd: "/work".into(),
        tagents_config_dir: Some("/c".into()),
        xdg_config_home: Some("/x".into()),
        knowledge_dir: Some("/k".into()),
        knowledge_db: Some("/k.db".into()),
        knowledge_usage_db: Some("/u.db".into()),
        ..Env::default()
    }
}

/// One change to the environment, named after the variable it touches.
type Change = fn(&mut Env);

const EXE: &str = "/opt/tagents/tagents-core";
const MTIME: i64 = 1_700_000_000_123;

#[test]
fn the_key_changes_with_each_variable_and_with_the_binary() {
    let stamp = code_stamp(EXE, MTIME);
    let key = server_key(&base(), &stamp);
    assert_eq!(12, key.len());
    assert!(key.bytes().all(|b| b.is_ascii_hexdigit()));
    assert_eq!(
        key,
        server_key(&base(), &stamp),
        "the same input, the same key"
    );

    let changes: [(&str, Change); 6] = [
        ("HOME", |env| env.home_var = Some("/home/v".into())),
        ("TAGENTS_CONFIG_DIR", |env| {
            env.tagents_config_dir = Some("/c2".into())
        }),
        ("XDG_CONFIG_HOME", |env| {
            env.xdg_config_home = Some("/x2".into())
        }),
        ("TAGENTS_KNOWLEDGE_DIR", |env| {
            env.knowledge_dir = Some("/k2".into())
        }),
        ("TAGENTS_KNOWLEDGE_DB", |env| {
            env.knowledge_db = Some("/k2.db".into())
        }),
        ("TAGENTS_KNOWLEDGE_USAGE_DB", |env| {
            env.knowledge_usage_db = Some("/u2.db".into())
        }),
    ];
    for (name, change) in changes {
        let mut env = base();
        change(&mut env);
        assert_ne!(key, server_key(&env, &stamp), "{name}");
    }
    assert_ne!(
        key,
        server_key(&base(), &code_stamp(EXE, MTIME + 1)),
        "the time"
    );
    assert_ne!(
        key,
        server_key(&base(), &code_stamp("/opt/other/tagents-core", MTIME)),
        "the path"
    );
}

#[test]
fn what_the_server_does_not_read_does_not_change_the_key() {
    let stamp = code_stamp(EXE, MTIME);
    let mut env = base();
    env.tmpdir = Some("/elsewhere".into());
    env.cwd = "/another".into();
    env.home = "/not/the/variable".into();
    assert_eq!(server_key(&base(), &stamp), server_key(&env, &stamp));
}

#[test]
fn unset_is_empty_and_a_relative_value_is_the_absolute_one() {
    let stamp = code_stamp(EXE, MTIME);
    let mut unset = base();
    unset.xdg_config_home = None;
    let mut empty = base();
    empty.xdg_config_home = Some(String::new());
    assert_eq!(server_key(&unset, &stamp), server_key(&empty, &stamp));

    let mut relative = base();
    relative.knowledge_dir = Some("docs/../notes".into());
    let mut absolute = base();
    absolute.knowledge_dir = Some("/work/notes".into());
    assert_eq!(server_key(&absolute, &stamp), server_key(&relative, &stamp));
    assert_eq!(
        Some("/work/notes".to_owned()),
        canonical(&relative).knowledge_dir
    );
}

/// The key of the design: the lines of the variables, then `code=rust:<path>:<time>`. Written out here so that the formula is pinned apart from the code that builds it, and so that it is not node's, which has no `rust:` and a fractional time.
#[test]
fn the_key_is_the_hash_of_the_lines_and_a_stamp_that_is_not_nodes() {
    let lines: String = key_lines(&base())
        .iter()
        .map(|line| format!("{line}\0"))
        .collect();
    let stamp = code_stamp(EXE, MTIME);
    assert_eq!(format!("rust:{EXE}:{MTIME}"), stamp);
    let rust = hash_of(&format!("{lines}code=rust:{EXE}:{MTIME}"))[..12].to_owned();
    assert_eq!(rust, server_key(&base(), &stamp));
    let node = hash_of(&format!("{lines}code={EXE}:{MTIME}"))[..12].to_owned();
    assert_ne!(
        node, rust,
        "a Rust daemon and a node daemon of one environment must not share a socket"
    );
}

#[test]
fn the_stamp_of_a_binary_is_its_path_and_its_time_in_whole_milliseconds() {
    let dir = scratch("knowledge-socket-stamp");
    let exe = dir.join("tagents-core");
    fs::write(&exe, "x").unwrap();
    // 1_700_000_000 s and 123.9 ms: the stamp floors, node's `Math.floor(mtimeMs)` does too.
    let time = SystemTime::UNIX_EPOCH + Duration::new(1_700_000_000, 123_900_000);
    fs::File::options()
        .write(true)
        .open(&exe)
        .unwrap()
        .set_modified(time)
        .unwrap();
    assert_eq!(
        Ok(format!("rust:{}:1700000000123", exe.display())),
        program_stamp(&exe)
    );
    let missing = program_stamp(&dir.join("nothing"));
    assert!(missing.is_err(), "{missing:?}");
}

#[test]
fn the_socket_is_named_after_the_key_in_the_directory_with_a_pid_file_and_a_lock_beside_it() {
    let mut env = base();
    env.tmpdir = Some("/var/x".into());
    let stamp = code_stamp(EXE, MTIME);
    let socket = socket_path(&env, uid(), &stamp);
    let key = server_key(&env, &stamp);
    assert_eq!(
        format!("/var/x/tagents-{}/knowledge-{key}.sock", uid()),
        socket
    );
    assert_eq!(format!("{socket}.pid"), pid_file_of(&socket));
    assert_eq!(format!("{socket}.lock"), lock_dir_of(&socket));
}

/// The longest name a socket in the directory can have is `knowledge-` and twelve digits and `.sock`, and the address allows 100 bytes of it: a directory that fits to the byte stays, one byte more goes under `/tmp`.
#[test]
fn a_directory_that_would_not_fit_a_socket_address_is_replaced_by_one_under_tmp() {
    let tagents = format!("tagents-{}", uid());
    let longest = "knowledge-000000000000.sock".len();
    // `/<name>/tagents-<uid>/<longest>`
    let fixed = 1 + 1 + tagents.len() + 1 + longest;
    for (extra, stays) in [(0, true), (1, false)] {
        let name = "a".repeat(100 - fixed + extra);
        let env = Env {
            tmpdir: Some(format!("/{name}")),
            ..Env::default()
        };
        let want = if stays {
            format!("/{name}/{tagents}")
        } else {
            format!("/tmp/{tagents}")
        };
        assert_eq!(want, socket_dir(&env, uid()), "{} bytes", 100 + extra);
    }
}

fn mode(path: &Path) -> u32 {
    fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn the_directory_is_made_private_and_a_loose_one_of_ours_is_tightened() {
    let root = scratch("knowledge-socket-dir");
    let nested = root.join("a/b/tagents-1");
    ensure_private_dir(&nested).unwrap();
    assert_eq!(0o700, mode(&nested));
    // Idempotent, and a mode that is already private is left as it is.
    ensure_private_dir(&nested).unwrap();
    assert_eq!(0o700, mode(&nested));

    let loose = root.join("loose");
    fs::create_dir(&loose).unwrap();
    fs::set_permissions(&loose, fs::Permissions::from_mode(0o755)).unwrap();
    ensure_private_dir(&loose).unwrap();
    assert_eq!(0o700, mode(&loose));

    // Only the group and others bits are looked at: an owner who took more away than the rule asks keeps it.
    let strict = root.join("strict");
    fs::create_dir(&strict).unwrap();
    fs::set_permissions(&strict, fs::Permissions::from_mode(0o500)).unwrap();
    ensure_private_dir(&strict).unwrap();
    assert_eq!(0o500, mode(&strict));
    fs::set_permissions(&strict, fs::Permissions::from_mode(0o700)).unwrap();
}

#[test]
fn a_file_a_link_or_a_directory_of_another_owner_is_refused() {
    let root = scratch("knowledge-socket-refused");
    let file = root.join("file");
    fs::write(&file, "").unwrap();
    // Making a directory where a file is fails the way node's `mkdirSync(.., { recursive: true })` does.
    assert_eq!(
        Err(format!(
            "EEXIST: file already exists, mkdir '{}'",
            file.display()
        )),
        ensure_private_dir(&file)
    );
    let real = root.join("real");
    fs::create_dir(&real).unwrap();
    let before = mode(&real);
    let link = root.join("link");
    symlink(&real, &link).unwrap();
    assert_eq!(
        Err(format!(
            "{} is not a directory of this user",
            link.display()
        )),
        ensure_private_dir(&link)
    );
    // The link was not followed to tighten what it points at.
    assert_eq!(before, mode(&real));
    // A directory that is somebody else's: the root of the file system is root's, unless root runs this.
    if uid() != 0 {
        assert_eq!(
            Err("/ is not a directory of this user".to_owned()),
            ensure_private_dir(Path::new("/"))
        );
    }
}

fn plain_env() -> Env {
    Env {
        home: "/home/me".into(),
        cwd: "/work/here".into(),
        ..Env::default()
    }
}

#[test]
fn okbs_own_variables_change_the_key_and_unset_ones_leave_it_as_it_was() {
    let base = plain_env();
    let key = |env: &Env| server_key(env, "stamp");
    let unset = key(&base);
    // Unset: no OKB line, the lines are exactly the ones of the node program.
    assert!(
        key_lines(&base)
            .iter()
            .all(|line| !line.starts_with("OKB_"))
    );
    assert_eq!(key_lines(&base).len(), KEY_VARS.len());
    let with_config = Env {
        okb_config_dir: Some("/cfg/okb".into()),
        ..base.clone()
    };
    let with_dir = Env {
        okb_dir: Some("/notes".into()),
        ..base.clone()
    };
    assert_ne!(key(&with_config), unset);
    assert_ne!(key(&with_dir), unset);
    assert_ne!(key(&with_config), key(&with_dir));
    assert!(key_lines(&with_config).contains(&"OKB_CONFIG_DIR=/cfg/okb".to_owned()));
    assert!(key_lines(&with_dir).contains(&"OKB_DIR=/notes".to_owned()));
}

#[test]
fn okbs_own_variables_are_made_absolute_and_exported_to_the_daemon() {
    let env = Env {
        okb_config_dir: Some("rel/cfg".into()),
        okb_dir: Some("~/notes".into()),
        ..plain_env()
    };
    let canon = canonical(&env);
    assert_eq!(canon.okb_config_dir.as_deref(), Some("/work/here/rel/cfg"));
    assert_eq!(canon.okb_dir.as_deref(), Some("~/notes"));
    let listed = exported(&env);
    assert!(listed.contains(&("OKB_CONFIG_DIR", "/work/here/rel/cfg".to_owned())));
    assert!(listed.contains(&("OKB_DIR", "~/notes".to_owned())));
    assert!(
        exported(&plain_env())
            .iter()
            .all(|(name, _)| !name.starts_with("OKB_"))
    );
}
