//! What node's `fs`, `path` and `os` modules do that `std` does not do the same way.
//!
//! The node CLI works on strings, so a path with bytes that are not UTF-8 reaches the kernel as another path.
//! Paths here are strings as well, which keeps the two programs looking at the same files.

use std::{
    ffi::{OsStr, OsString},
    fs, io,
    os::unix::{fs::MetadataExt, process::CommandExt},
    path::{Path, PathBuf},
    process::Command,
};

use crate::js;

/// The node binary the wrapper `install.sh` writes pinned, or `node` on `PATH`.
const NODE_ENV: &str = "TAGENTS_NODE";

/// `os.homedir()`: `$HOME` when it is set, empty or not, else the passwd entry.
pub fn homedir() -> String {
    match std::env::var_os("HOME") {
        Some(home) => home.to_string_lossy().into_owned(),
        None => std::env::home_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default(),
    }
}

/// `path.basename(p)`: the last segment, trailing slashes ignored.
pub fn basename(p: &str) -> &str {
    let trimmed = p.trim_end_matches('/');
    trimmed.rsplit('/').next().unwrap_or("")
}

/// `path.join(base, name)`: joined with a slash, then normalised (`.` and `..` and doubled slashes resolved lexically).
pub fn join(base: &str, name: &str) -> String {
    let joined = match (base.is_empty(), name.is_empty()) {
        (true, true) => String::new(),
        (true, false) => name.to_owned(),
        (false, true) => base.to_owned(),
        (false, false) => format!("{base}/{name}"),
    };
    if joined.is_empty() {
        return ".".to_owned();
    }
    let absolute = joined.starts_with('/');
    let trailing = joined.ends_with('/');
    let mut kept: Vec<&str> = Vec::new();
    for segment in joined.split('/') {
        match segment {
            "" | "." => {}
            ".." if kept.last().is_some_and(|last| *last != "..") => {
                kept.pop();
            }
            ".." if absolute => {}
            other => kept.push(other),
        }
    }
    let body = kept.join("/");
    match (absolute, body.is_empty(), trailing) {
        (true, true, _) => "/".to_owned(),
        (false, true, true) => "./".to_owned(),
        (false, true, false) => ".".to_owned(),
        (true, false, true) => format!("/{body}/"),
        (true, false, false) => format!("/{body}"),
        (false, false, true) => format!("{body}/"),
        (false, false, false) => body,
    }
}

/// `stat.mtime.getTime()`: node computes `sec * 1e3 + nsec / 1e6` as a float and `Date` takes `Math.round` of it.
pub fn mtime_ms(meta: &fs::Metadata) -> i64 {
    js::round(meta.mtime() as f64 * 1000.0 + meta.mtime_nsec() as f64 / 1e6) as i64
}

/// An error number with node's name and text for it, as `util.getSystemErrorMap()` gives them.
pub struct Errno {
    pub number: i32,
    pub code: &'static str,
    pub message: &'static str,
}

/// The errors the daemon names the way node does. Only those whose number is the same on Linux and macOS are listed; `tests/notify_vectors/errno.rs` compares every code and text with libuv's, which do not depend on the system.
pub const ERRNOS: &[Errno] = &[
    Errno {
        number: 2,
        code: "ENOENT",
        message: "no such file or directory",
    },
    Errno {
        number: 5,
        code: "EIO",
        message: "i/o error",
    },
    Errno {
        number: 7,
        code: "E2BIG",
        message: "argument list too long",
    },
    Errno {
        number: 8,
        code: "ENOEXEC",
        message: "exec format error",
    },
    Errno {
        number: 12,
        code: "ENOMEM",
        message: "not enough memory",
    },
    Errno {
        number: 13,
        code: "EACCES",
        message: "permission denied",
    },
    Errno {
        number: 20,
        code: "ENOTDIR",
        message: "not a directory",
    },
    Errno {
        number: 21,
        code: "EISDIR",
        message: "illegal operation on a directory",
    },
    Errno {
        number: 24,
        code: "EMFILE",
        message: "too many open files",
    },
    Errno {
        number: 26,
        code: "ETXTBSY",
        message: "text file is busy",
    },
];

/// The table's entry for the error's number, `None` for an error without one or one the table does not name.
pub fn errno(err: &io::Error) -> Option<&'static Errno> {
    let number = err.raw_os_error()?;
    ERRNOS.iter().find(|e| e.number == number)
}

/// The text of the `Error` node throws for a failed syscall: `EACCES: permission denied, open '/x'`. An error the table does not name prints what Rust says.
pub fn io_message(err: &io::Error, syscall: &str, path: Option<&str>) -> String {
    let Some(Errno { code, message, .. }) = errno(err) else {
        return err.to_string();
    };
    match path {
        Some(path) => format!("{code}: {message}, {syscall} '{path}'"),
        None => format!("{code}: {message}, {syscall}"),
    }
}

/// The root this binary belongs to: `<root>/target/{release,debug}/tagents-core` lives two directories below it. The error is why there was none.
pub fn root() -> Result<PathBuf, String> {
    let exe = std::env::current_exe()
        .and_then(|exe| exe.canonicalize())
        .map_err(|e| format!("cannot tell where this binary is: {e}"))?;
    root_of(&exe)
}

fn root_of(exe: &Path) -> Result<PathBuf, String> {
    exe.ancestors()
        .nth(3)
        .map(Path::to_path_buf)
        .ok_or_else(|| {
            format!(
                "{} is too close to the root of the file system",
                exe.display()
            )
        })
}

/// A node program that belongs to this binary, `relative` to its root. The error is the path that was looked at, or why there was none.
pub fn program(relative: &str) -> Result<PathBuf, String> {
    program_in(&root()?, relative)
}

fn program_in(root: &Path, relative: &str) -> Result<PathBuf, String> {
    let program = root.join(relative);
    if program.is_file() {
        Ok(program)
    } else {
        Err(format!("{} is not a file", program.display()))
    }
}

/// Why `exec` could not replace the process. Nothing is printed: the caller words it and chooses the exit code.
#[derive(Debug)]
pub enum ExecFailure {
    /// The program is not a file below the root: what `program` said.
    Missing(String),
    /// The node binary could not be run, with the error the system gave for it.
    Run { node: OsString, err: io::Error },
}

/// Replace this process with the node program at `relative` below the root, given `args`, in the same environment. Only returns when that could not be done.
pub fn exec(relative: &str, args: &[OsString]) -> ExecFailure {
    let program = match program(relative) {
        Ok(program) => program,
        Err(why) => return ExecFailure::Missing(why),
    };
    let node = std::env::var_os(NODE_ENV)
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| OsString::from("node"));
    exec_with(&node, &program, args)
}

fn exec_with(node: &OsStr, program: &Path, args: &[OsString]) -> ExecFailure {
    let err = Command::new(node).arg(program).args(args).exec();
    ExecFailure::Run {
        node: node.to_owned(),
        err,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basename_ignores_trailing_slashes() {
        for (path, want) in [
            ("/a/b", "b"),
            ("/a/b///", "b"),
            ("b", "b"),
            ("/", ""),
            ("", ""),
            ("..", ".."),
            ("/a/.claude-x/", ".claude-x"),
        ] {
            assert_eq!(basename(path), want, "{path:?}");
        }
    }

    #[test]
    fn join_normalises_like_path_join() {
        for (base, name, want) in [
            ("/a/b", "projects", "/a/b/projects"),
            ("/a//b/", "projects", "/a/b/projects"),
            ("/a/b/../c", "projects", "/a/c/projects"),
            ("/a/./b", "projects", "/a/b/projects"),
            ("/../a", "p", "/a/p"),
            ("a/../..", "p", "../p"),
            ("rel", "p", "rel/p"),
            ("", ".claude", ".claude"),
            ("", "", "."),
            ("/", "p", "/p"),
            ("/a", "..", "/"),
            ("a", "..", "."),
            ("a/", "", "a/"),
            ("/a/b/", "", "/a/b/"),
        ] {
            assert_eq!(join(base, name), want, "{base:?} + {name:?}");
        }
    }

    #[test]
    fn the_root_is_three_levels_above_the_binary() {
        assert_eq!(
            root_of(Path::new("/work/tagents/target/debug/tagents-core")).unwrap(),
            Path::new("/work/tagents")
        );
        let why = root_of(Path::new("/target/tagents-core")).unwrap_err();
        assert_eq!(
            why,
            "/target/tagents-core is too close to the root of the file system"
        );
    }

    #[test]
    fn a_program_is_a_file_below_the_root_or_the_path_that_is_not() {
        let dir = std::env::temp_dir().join(format!("tagents-node-test-{}", std::process::id()));
        fs::create_dir_all(dir.join("packages")).unwrap();
        fs::write(dir.join("packages/main.js"), "").unwrap();
        assert_eq!(
            program_in(&dir, "packages/main.js").unwrap(),
            dir.join("packages/main.js")
        );
        // A directory is not a program either.
        assert_eq!(
            program_in(&dir, "packages").unwrap_err(),
            format!("{} is not a file", dir.join("packages").display())
        );
        assert_eq!(
            program_in(&dir, "packages/other.js").unwrap_err(),
            format!("{} is not a file", dir.join("packages/other.js").display())
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_node_that_cannot_run_comes_back_as_the_error_of_the_exec() {
        let failure = exec_with(
            OsStr::new("/no/such/node-binary"),
            Path::new("/x/main.js"),
            &[OsString::from("run")],
        );
        match failure {
            ExecFailure::Run { node, err } => {
                assert_eq!(node, "/no/such/node-binary");
                assert_eq!(err.kind(), io::ErrorKind::NotFound);
            }
            ExecFailure::Missing(why) => panic!("the program was found: {why}"),
        }
    }
}
