//! What node's `fs`, `path` and `os` modules do that `std` does not do the same way.
//!
//! The node CLI works on strings, so a path with bytes that are not UTF-8 reaches the kernel as another path.
//! Paths here are strings as well, which keeps the two programs looking at the same files.

use std::{
    ffi::OsString,
    fs, io,
    os::unix::{fs::MetadataExt, process::CommandExt},
    path::{Path, PathBuf},
    process::Command,
    sync::{Arc, atomic::AtomicBool},
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

/// `path.resolve(base, path)` for an absolute `base`: `path` itself when it is absolute, else below `base`; normalised, with no trailing slash but the root's.
pub fn resolve(base: &str, path: &str) -> String {
    let full = match path {
        "" => base.to_owned(),
        _ if path.starts_with('/') => path.to_owned(),
        _ => format!("{base}/{path}"),
    };
    let normalised = join(&full, "");
    match normalised.trim_end_matches('/') {
        "" => "/".to_owned(),
        trimmed => trimmed.to_owned(),
    }
}

/// `path.relative(from, to)` for absolute paths: the segments of `to` below their common ancestor, each segment of `from` below it becoming `..`.
pub fn relative(from: &str, to: &str) -> String {
    let (from, to) = (resolve("/", from), resolve("/", to));
    let segments = |p: &str| -> Vec<String> {
        p.split('/')
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect()
    };
    let (from, to) = (segments(&from), segments(&to));
    let common = from.iter().zip(&to).take_while(|(a, b)| a == b).count();
    let ups = std::iter::repeat_n("..".to_owned(), from.len() - common);
    ups.chain(to[common..].iter().cloned())
        .collect::<Vec<_>>()
        .join("/")
}

/// `fs.realpathSync(path)`, the JavaScript one and not `realpathSync.native`: the symbolic links of an absolute `path` resolved a component at a time, every other component kept as written. `fs::canonicalize` writes a directory in the case the disk holds, so on a case-insensitive volume `plugin add Plain` would name another directory than node does for a package installed as `plain`. A link followed more than `MAX_LINKS` times is `ELOOP`, and so is a path that holds that many links in all, a stricter rule than node's, which both callers turn into a hand-over; a component that is missing or cannot be read is the system's error.
pub fn realpath(path: &str) -> io::Result<String> {
    // Node leaves the limit to the kernel, which answers ELOOP after 32 links on macOS and 40 on Linux; the smaller of the two, so that no chain is resolved here that node on macOS refuses.
    const MAX_LINKS: usize = 32;
    // The next component is the last of the stack, so a link's target goes on top of what is left to walk.
    let components = |p: &str| -> Vec<String> {
        p.split('/')
            .filter(|s| !s.is_empty())
            .rev()
            .map(str::to_owned)
            .collect()
    };
    let mut pending = components(&resolve("/", path));
    let mut real = String::new();
    let mut links = 0;
    while let Some(part) = pending.pop() {
        let here = format!("{real}/{part}");
        if !fs::symlink_metadata(&here)?.file_type().is_symlink() {
            real = here;
            continue;
        }
        links += 1;
        if links > MAX_LINKS {
            return Err(io::Error::from_raw_os_error(
                rustix::io::Errno::LOOP.raw_os_error(),
            ));
        }
        let target = fs::read_link(&here)?;
        let target = target
            .to_str()
            .ok_or_else(|| io::Error::from(io::ErrorKind::InvalidData))?;
        let parent = if real.is_empty() { "/" } else { &real };
        pending.extend(components(&resolve(parent, target)));
        real.clear();
    }
    Ok(if real.is_empty() {
        "/".to_owned()
    } else {
        real
    })
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

/// `isExecutableFile`: a regular file this process may execute, a symlink followed. Answered by looking, never by running it.
fn is_executable_file(file: &str) -> bool {
    rustix::fs::access(file, rustix::fs::Access::EXEC_OK).is_ok()
        && fs::metadata(file).is_ok_and(|meta| meta.is_file())
}

/// `findOnPath`: the first `name` on `path_var` (the value of `PATH`) that is an executable file, as found, the one a shell would pick.
pub fn find_on_path(name: &str, path_var: &str) -> Option<String> {
    path_var
        .split(':')
        .filter(|dir| !dir.is_empty())
        .map(|dir| join(dir, name))
        .find(|file| is_executable_file(file))
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

/// The node binary: what `$TAGENTS_NODE` names unless it is empty, else `node` on `PATH`.
pub fn interpreter() -> OsString {
    std::env::var_os(NODE_ENV)
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| OsString::from("node"))
}

/// Why `exec` could not replace the process. Nothing is printed: the caller words it and chooses the exit code.
#[derive(Debug)]
pub enum ExecFailure {
    /// The program is not a file below the root: what `program` said.
    Missing(String),
    /// The node binary could not be run, with the error the system gave for it.
    Run { node: OsString, err: io::Error },
}

/// Replace this process with the node program at `relative` below the root, given `args`, in the same environment. Only returns when that could not be done, and then with SIGPIPE caught again: `Command::exec` leaves it at its default, which would kill a caller that writes its line to a closed stderr instead of letting it exit with its own code.
pub fn exec(relative: &str, args: &[OsString]) -> ExecFailure {
    let program = match program(relative) {
        Ok(program) => program,
        Err(why) => return ExecFailure::Missing(why),
    };
    let node = interpreter();
    let err = Command::new(&node).arg(program).args(args).exec();
    // A handler that only sets a flag is the safe form of ignoring the signal; a failed registration leaves the default, which is all there was.
    let _ = signal_hook::flag::register(
        signal_hook::consts::SIGPIPE,
        Arc::new(AtomicBool::new(false)),
    );
    ExecFailure::Run { node, err }
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
    fn resolve_is_path_resolve_below_an_absolute_base() {
        for (base, path, want) in [
            ("/w/x", "a", "/w/x/a"),
            ("/w/x", "./a/", "/w/x/a"),
            ("/w/x", "../a", "/w/a"),
            ("/w/x", "../../..", "/"),
            ("/w/x", "../../../a", "/a"),
            ("/w/x", "/a/./b/../c//", "/a/c"),
            ("/w/x", "", "/w/x"),
            ("/w/x/", ".", "/w/x"),
            ("/", "a", "/a"),
            ("/", "..", "/"),
            ("/w", "a b/\u{e9}", "/w/a b/\u{e9}"),
        ] {
            assert_eq!(resolve(base, path), want, "{base:?} + {path:?}");
        }
    }

    #[test]
    fn relative_is_path_relative() {
        for (from, to, want) in [
            ("/a/b", "/a/b", ""),
            ("/a/b", "/a/b/c/d", "c/d"),
            ("/a/b/c", "/a/b", ".."),
            ("/a/b/c", "/a/d", "../../d"),
            ("/a/b", "/x/y", "../../x/y"),
            ("/", "/a", "a"),
            ("/a", "/", ".."),
            ("/a/bc", "/a/b", "../b"),
            ("/a/b", "/a/bc", "../bc"),
            ("/a/b/", "/a//b/./c", "c"),
            ("/a/b", "/a/.hidden/x", "../.hidden/x"),
        ] {
            assert_eq!(relative(from, to), want, "{from:?} -> {to:?}");
        }
    }

    /// A scratch directory under its canonical name (the system's temp directory is itself reached through a link on macOS), with `real/dir/file` in it.
    fn realpath_tree() -> (crate::testing::Scratch, String) {
        let scratch = crate::testing::Scratch::new();
        let root = fs::canonicalize(scratch.path()).unwrap();
        fs::create_dir_all(root.join("real/dir")).unwrap();
        fs::write(root.join("real/dir/file"), "").unwrap();
        let root = root.to_str().unwrap().to_owned();
        (scratch, root)
    }

    #[test]
    fn realpath_follows_links_in_the_middle_and_at_the_end_of_a_path() {
        use std::os::unix::fs::symlink;
        let (_scratch, root) = realpath_tree();
        // A chain, a link with a relative target that climbs, and a link to a directory with more path below it.
        symlink("real", format!("{root}/one")).unwrap();
        symlink("one/dir", format!("{root}/two")).unwrap();
        symlink("../two/file", format!("{root}/real/up")).unwrap();
        symlink(format!("{root}/real"), format!("{root}/absolute")).unwrap();
        for (path, want) in [
            (format!("{root}/real/dir/file"), "real/dir/file"),
            (format!("{root}/one"), "real"),
            (format!("{root}/two"), "real/dir"),
            (format!("{root}/two/file"), "real/dir/file"),
            (format!("{root}/real/up"), "real/dir/file"),
            (format!("{root}/absolute/dir/./../dir"), "real/dir"),
            (format!("{root}/real//dir/"), "real/dir"),
        ] {
            assert_eq!(realpath(&path).unwrap(), format!("{root}/{want}"), "{path}");
        }
        assert_eq!(realpath("/").unwrap(), "/");
    }

    #[test]
    fn realpath_fails_as_the_system_does_for_a_missing_component_and_a_loop() {
        use std::os::unix::fs::symlink;
        let (_scratch, root) = realpath_tree();
        symlink("nowhere", format!("{root}/dangling")).unwrap();
        symlink("b", format!("{root}/a")).unwrap();
        symlink("a", format!("{root}/b")).unwrap();
        let missing = realpath(&format!("{root}/real/absent/file")).unwrap_err();
        assert_eq!(missing.kind(), io::ErrorKind::NotFound);
        let dangling = realpath(&format!("{root}/dangling")).unwrap_err();
        assert_eq!(dangling.kind(), io::ErrorKind::NotFound);
        let looped = realpath(&format!("{root}/a")).unwrap_err();
        assert_eq!(
            looped.raw_os_error(),
            Some(rustix::io::Errno::LOOP.raw_os_error())
        );
    }

    /// A chain of `length` links, `link1` to `link<length>`, the last one pointing at `real`.
    fn link_chain(root: &str, length: usize) {
        use std::os::unix::fs::symlink;
        for number in 1..length {
            symlink(
                format!("link{}", number + 1),
                format!("{root}/link{number}"),
            )
            .unwrap();
        }
        symlink("real", format!("{root}/link{length}")).unwrap();
    }

    #[test]
    fn realpath_resolves_a_chain_of_32_links_and_refuses_one_of_33_as_the_smallest_kernel_does() {
        let (_scratch, root) = realpath_tree();
        link_chain(&root, 32);
        assert_eq!(
            realpath(&format!("{root}/link1")).unwrap(),
            format!("{root}/real")
        );

        let (_scratch, root) = realpath_tree();
        link_chain(&root, 33);
        let refused = realpath(&format!("{root}/link1")).unwrap_err();
        assert_eq!(
            refused.raw_os_error(),
            Some(rustix::io::Errno::LOOP.raw_os_error())
        );
    }

    /// `fs::canonicalize` writes a directory in the case the disk holds and node's `fs.realpathSync` in the case it was given, which matters on a case-insensitive volume (macOS) and nowhere else.
    #[test]
    fn realpath_keeps_the_case_it_was_given() {
        let (_scratch, root) = realpath_tree();
        let given = format!("{root}/REAL/dir");
        if fs::metadata(&given).is_err() {
            return;
        }
        assert_eq!(realpath(&given).unwrap(), given);
    }

    /// A scratch directory holding `files` as (name, mode) pairs, each with a body that makes it a file.
    fn bin_dir(tag: &str, files: &[(&str, u32)]) -> String {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("tagents-node-{tag}-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        for (name, mode) in files {
            let file = dir.join(name);
            fs::write(&file, "#!/bin/sh\n").unwrap();
            fs::set_permissions(&file, fs::Permissions::from_mode(*mode)).unwrap();
        }
        dir.to_string_lossy().into_owned()
    }

    #[test]
    fn the_first_executable_file_on_the_path_is_found_as_it_is_named() {
        let first = bin_dir("first", &[("tagents", 0o644), ("other", 0o755)]);
        let second = bin_dir("second", &[("tagents", 0o755)]);
        let third = bin_dir("third", &[("tagents", 0o755)]);
        // A directory of that name and a file that cannot be run are skipped, empty entries and missing directories too.
        fs::create_dir_all(format!("{second}/dir-tagents")).unwrap();
        let path_var = format!(":{first}::/no/such/dir:{second}:{third}");
        assert_eq!(
            find_on_path("tagents", &path_var),
            Some(format!("{second}/tagents"))
        );
        assert_eq!(
            find_on_path("other", &path_var),
            Some(format!("{first}/other"))
        );
        assert_eq!(find_on_path("dir-tagents", &path_var), None);
        assert_eq!(find_on_path("tagents", ""), None);
        // A symlink is a file, and the path is the symlink, not what it points to.
        std::os::unix::fs::symlink(format!("{third}/tagents"), format!("{first}/linked")).unwrap();
        assert_eq!(
            find_on_path("linked", &first),
            Some(format!("{first}/linked"))
        );
        for dir in [first, second, third] {
            fs::remove_dir_all(dir).unwrap();
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
}
