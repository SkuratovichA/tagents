//! Starting the child of a turn, as the driver's `spawn` starts it (design D4), and what a failure to start it becomes (design D5).
//!
//! On Linux `Command` ends in the `execvp` that libuv's child ends in, and the `PATH` it reads is the child's. On macOS libuv walks that `PATH` itself, with one `posix_spawn` per entry, and `Command` with a bare name goes through the libc's `execvp`. So on macOS this file walks `PATH` the way libuv does and gives `Command` each file by its absolute path. A relative path is resolved against the working directory of the child before it is given to `Command`.
//!
//! `ENOEXEC` never reaches `Command` on macOS: the libc's `posix_spawnp` answers it by running the file through `/bin/sh`, where libuv's `posix_spawn` reports it. So a file that could get that answer is reported as `spawn ENOEXEC` before it is started, by reading what the kernel reads (see `kernel_may_refuse`). A relative path is resolved against the working directory of the child, where libuv's forked child changes directory before it spawns.
//!
//! What `spawn` reports is worded as node words it: the codes node delivers as the `error` event are `Failed`, every other code is thrown (`failure`).

use std::io;
#[cfg(target_os = "macos")]
use std::io::Read;
#[cfg(target_os = "macos")]
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};

use crate::node;
use crate::session::command::Invocation;

/// What starting the child gave.
#[derive(Debug)]
pub enum Start {
    Started(Child),
    /// The `error` event of `spawn`: the outcome `spawn-failed` with this detail.
    Failed(String),
    /// What `spawn` throws: this message alone on stderr, and no outcome.
    Thrown(String),
}

/// The child, whichever file it ends up running: its name stays the name as given, in no process group of its own.
fn command(invocation: &Invocation, file: &str) -> Command {
    let mut command = Command::new(file);
    command
        .arg0(&invocation.program)
        .args(&invocation.args)
        .env_clear()
        .envs(&invocation.env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if !invocation.cwd.is_empty() {
        command.current_dir(&invocation.cwd);
    }
    command
}

/// `command` started, past an interrupted call. In a test binary the fork gate is held for this and nothing longer.
pub(crate) fn spawn_uninterrupted(command: &mut Command) -> io::Result<Child> {
    loop {
        #[cfg(test)]
        let _spawning = crate::testing::gate::spawning();
        match command.spawn() {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            started => return started,
        }
    }
}

/// One start of the child from `file`.
fn attempt(invocation: &Invocation, file: &str) -> io::Result<Child> {
    spawn_uninterrupted(&mut command(invocation, file))
}

/// `spawn`'s two ways of failing: libuv delivers `UV_EACCES`, `UV_EAGAIN`, `UV_EMFILE`, `UV_ENFILE` and `UV_ENOENT` as the `error` event of the child, and node throws every other code from the call itself. An error without a name in the table is worded as Rust words it.
fn failure(program: &str, error: &io::Error) -> Start {
    let again = [
        rustix::io::Errno::AGAIN.raw_os_error(),
        rustix::io::Errno::NFILE.raw_os_error(),
    ];
    if error
        .raw_os_error()
        .is_some_and(|number| again.contains(&number))
    {
        let code = if error.raw_os_error() == Some(again[0]) {
            "EAGAIN"
        } else {
            "ENFILE"
        };
        return Start::Failed(format!("spawn {program} {code}"));
    }
    match node::errno(error).map(|errno| errno.code) {
        Some(code @ ("ENOENT" | "EACCES" | "EMFILE")) => {
            Start::Failed(format!("spawn {program} {code}"))
        }
        Some(code) => Start::Thrown(format!("spawn {code}")),
        None => Start::Thrown(format!("spawn {error}")),
    }
}

/// `IMG_SHSIZE`: how much of a file the kernel of macOS reads to decide what it is.
#[cfg(target_os = "macos")]
const HEADER_SIZE: u64 = 512;

#[cfg(target_os = "macos")]
fn header(path: &str) -> io::Result<Vec<u8>> {
    let mut header = Vec::new();
    std::fs::File::open(path)?
        .take(HEADER_SIZE)
        .read_to_end(&mut header)?;
    Ok(header)
}

/// The magic of a Mach-O file or of a fat one, as they are on the disk of this machine.
#[cfg(target_os = "macos")]
fn is_machine_code(header: &[u8]) -> bool {
    matches!(
        header.get(..4),
        Some([0xcf | 0xce, 0xfa, 0xed, 0xfe] | [0xca, 0xfe, 0xba, 0xbe])
    )
}

/// The program a `#!` line names, as `exec_shell_imgact` reads it, where `#` also ends the line. `None` for no such line and for one it refuses: no program, or no end within what it reads.
#[cfg(target_os = "macos")]
fn interpreter_line(header: &[u8]) -> Option<&[u8]> {
    let rest = header.strip_prefix(b"#!")?;
    let start = rest.iter().position(|byte| !matches!(byte, b' ' | b'\t'))?;
    let rest = &rest[start..];
    let end = rest.iter().position(|byte| matches!(byte, b'\n' | b'#'))?;
    let line = &rest[..end];
    let name = line
        .iter()
        .position(|byte| matches!(byte, b' ' | b'\t'))
        .map_or(line, |end| &line[..end]);
    (!name.is_empty()).then_some(name)
}

/// Whether the kernel may answer `file` with `ENOEXEC`, or this cannot tell that it will not. A name or a mode it refuses comes first, so that is not this question: the start reports it. The answer is true for what is not machine code and not a script with machine code as its interpreter, and a script's interpreter that cannot be there gives the start its error.
#[cfg(target_os = "macos")]
fn kernel_may_refuse(file: &str) -> bool {
    let Ok(metadata) = std::fs::metadata(file) else {
        return false;
    };
    if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return false;
    }
    let Ok(head) = header(file) else {
        return true;
    };
    if is_machine_code(&head) {
        return false;
    }
    let name = interpreter_line(&head).and_then(|name| std::str::from_utf8(name).ok());
    let Some(name) = name.filter(|name| name.starts_with('/')) else {
        return true;
    };
    match header(name) {
        Ok(head) => !is_machine_code(&head),
        Err(error) => !matches!(
            node::errno(&error).map(|errno| errno.code),
            Some("ENOENT" | "ENOTDIR")
        ),
    }
}

#[cfg(target_os = "macos")]
pub fn start(invocation: &Invocation) -> Start {
    /// `_PATH_DEFPATH`, for a child with no `PATH`.
    const DEFAULT_PATH: &str = "/usr/bin:/bin";

    let program = invocation.program.as_str();
    let single = [program.to_owned()];
    let files: Box<dyn Iterator<Item = String>> = if program.contains('/') {
        Box::new(single.into_iter())
    } else {
        let path = invocation
            .env
            .get("PATH")
            .map_or(DEFAULT_PATH, String::as_str);
        Box::new(path.split(':').map(move |entry| match entry {
            "" => program.to_owned(),
            entry => format!("{entry}/{program}"),
        }))
    };
    // What libuv remembers: a file that was denied outranks the error of the last entry.
    let mut denied = None;
    let mut last = None;
    for file in files {
        let file = if file.starts_with('/') || invocation.cwd.is_empty() {
            file
        } else {
            node::resolve(&invocation.cwd, &file)
        };
        if kernel_may_refuse(&file) {
            return Start::Thrown("spawn ENOEXEC".to_owned());
        }
        match attempt(invocation, &file) {
            Ok(child) => return Start::Started(child),
            Err(error) => match node::errno(&error).map(|errno| errno.code) {
                Some("EACCES") => denied = Some(error),
                Some("ENOENT" | "ENOTDIR") => last = Some(error),
                _ => return failure(program, &error),
            },
        }
    }
    denied.or(last).map_or_else(
        || Start::Failed(format!("spawn {program} ENOENT")),
        |error| failure(program, &error),
    )
}

#[cfg(not(target_os = "macos"))]
pub fn start(invocation: &Invocation) -> Start {
    match attempt(invocation, &invocation.program) {
        Ok(child) => Start::Started(child),
        Err(error) => failure(&invocation.program, &error),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::fs;
    use std::path::Path;
    use std::sync::mpsc;
    use std::time::Duration;

    use rustix::process::{Pid, getpgid, getpgrp};

    use super::*;
    use crate::testing::{Scratch, gate};

    const WITNESS: &str = "#!/bin/sh\nprintf '%s|%s\\n' \"$*\" \"$(pwd -P)\"\n[ /dev/fd/0 -ef /dev/null ] && echo stdin-is-the-null-device\nprintf 'on stderr\\n' >&2\n";

    fn invocation(program: &str, path: &str, cwd: &str) -> Invocation {
        Invocation {
            program: program.to_owned(),
            args: vec!["-p".to_owned(), "a b".to_owned()],
            env: BTreeMap::from([("PATH".to_owned(), path.to_owned())]),
            cwd: cwd.to_owned(),
        }
    }

    fn text(path: &Path) -> String {
        path.to_str().unwrap().to_owned()
    }

    fn failed(start: &Start) -> &str {
        match start {
            Start::Failed(detail) => detail,
            other => panic!("not an event of spawn: {other:?}"),
        }
    }

    fn output_of(start: Start) -> std::process::Output {
        match start {
            Start::Started(child) => child.wait_with_output().unwrap(),
            other => panic!("not started: {other:?}"),
        }
    }

    /// A writer of an executable holds the spawn off, and a child that lives on holds the writer off no longer.
    #[test]
    fn a_spawn_takes_the_fork_gate_and_gives_it_back_before_the_child_ends() {
        let scratch = Scratch::new();
        let bin = scratch.path().join("bin");
        gate::write_executable(&bin.join("claude"), "#!/bin/sh\nexec sleep 30\n");
        let given = invocation("claude", &format!("{}:/usr/bin:/bin", text(&bin)), "");
        let writer = gate::writing();
        let (send, started) = mpsc::channel();
        let starter = std::thread::spawn(move || send.send(start(&given)).unwrap());
        assert!(
            started.recv_timeout(Duration::from_millis(200)).is_err(),
            "the spawn did not wait for the writer"
        );
        drop(writer);
        let start = started.recv().unwrap();
        starter.join().unwrap();
        let Start::Started(mut child) = start else {
            panic!("not started: {start:?}")
        };
        drop(gate::writing());
        child.kill().unwrap();
        child.wait().unwrap();
    }

    #[test]
    fn a_program_that_is_not_on_the_path_is_the_event_with_the_name_as_given() {
        let scratch = Scratch::new();
        let path = format!("{0}/a:{0}/b", scratch.path().display());
        assert_eq!(
            failed(&start(&invocation("claude", &path, ""))),
            "spawn claude ENOENT"
        );
        let missing = text(&scratch.path().join("no-such-file"));
        assert_eq!(
            failed(&start(&invocation(&missing, &path, ""))),
            format!("spawn {missing} ENOENT")
        );
    }

    #[test]
    fn a_working_directory_that_is_missing_reads_as_a_missing_program() {
        let scratch = Scratch::new();
        gate::write_executable(&scratch.path().join("bin/claude"), WITNESS);
        let path = text(&scratch.path().join("bin"));
        let cwd = text(&scratch.path().join("no-such-directory"));
        assert_eq!(
            failed(&start(&invocation("claude", &path, &cwd))),
            "spawn claude ENOENT"
        );
    }

    #[test]
    fn a_file_that_cannot_be_run_is_the_event_and_a_good_one_later_on_the_path_is_run() {
        let scratch = Scratch::new();
        let (plain, good) = (scratch.path().join("plain"), scratch.path().join("good"));
        fs::create_dir_all(&plain).unwrap();
        fs::write(plain.join("claude"), "not executable").unwrap();
        gate::write_executable(&good.join("claude"), WITNESS);
        let only_plain = text(&plain);
        assert_eq!(
            failed(&start(&invocation("claude", &only_plain, ""))),
            "spawn claude EACCES"
        );
        let both = format!("{}:{}", text(&plain), text(&good));
        let output = output_of(start(&invocation("claude", &both, "")));
        assert!(output.status.success());
    }

    #[test]
    fn a_directory_that_has_the_name_is_passed_over_and_counts_as_denied() {
        let scratch = Scratch::new();
        let (dirs, good) = (scratch.path().join("dirs"), scratch.path().join("good"));
        fs::create_dir_all(dirs.join("claude")).unwrap();
        gate::write_executable(&good.join("claude"), WITNESS);
        let only_dir = text(&dirs);
        assert_eq!(
            failed(&start(&invocation("claude", &only_dir, ""))),
            "spawn claude EACCES"
        );
        let denied_outranks_the_last = format!("{}:{}/none", text(&dirs), text(&good));
        assert_eq!(
            failed(&start(&invocation("claude", &denied_outranks_the_last, ""))),
            "spawn claude EACCES"
        );
        let both = format!("{}:{}", text(&dirs), text(&good));
        assert!(
            output_of(start(&invocation("claude", &both, "")))
                .status
                .success()
        );
    }

    #[test]
    fn a_working_directory_that_is_a_file_is_the_bare_message() {
        let scratch = Scratch::new();
        gate::write_executable(&scratch.path().join("bin/claude"), WITNESS);
        let file = scratch.path().join("a-file");
        fs::write(&file, "x").unwrap();
        match start(&invocation(
            "claude",
            &text(&scratch.path().join("bin")),
            &text(&file),
        )) {
            Start::Thrown(message) => assert_eq!(message, "spawn ENOTDIR"),
            other => panic!("not what spawn throws: {other:?}"),
        }
    }

    #[test]
    fn a_path_that_ends_with_a_file_is_the_bare_message_and_one_that_starts_with_it_is_not() {
        let scratch = Scratch::new();
        let file = scratch.path().join("a-file");
        fs::write(&file, "x").unwrap();
        let (file, none) = (text(&file), text(&scratch.path().join("none")));
        match start(&invocation("claude", &format!("{none}:{file}"), "")) {
            Start::Thrown(message) => assert_eq!(message, "spawn ENOTDIR"),
            other => panic!("not what spawn throws: {other:?}"),
        }
        assert_eq!(
            failed(&start(&invocation("claude", &format!("{file}:{none}"), ""))),
            "spawn claude ENOENT"
        );
    }

    #[test]
    fn another_errno_is_thrown_by_its_code() {
        let scratch = Scratch::new();
        let looping = scratch.path().join("loop");
        fs::create_dir_all(&looping).unwrap();
        std::os::unix::fs::symlink("claude", looping.join("claude")).unwrap();
        let start = start(&invocation("claude", &text(&looping), ""));
        assert!(
            matches!(&start, Start::Thrown(m) if m == "spawn ELOOP"),
            "{start:?}"
        );
    }

    /// The files the kernel of macOS refuses, which `Command` would run through `/bin/sh`.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_file_the_kernel_refuses_is_enoexec_on_macos() {
        let scratch = Scratch::new();
        let script = scratch.path().join("script");
        gate::write_executable(&script, "#!/bin/sh\n");
        let long = format!("#!/bin/{}\n", "s".repeat(600));
        let on_a_script = format!("#!{}\n", text(&script));
        for content in [
            "echo no interpreter line\n",
            "",
            "#!",
            "#!\n",
            "#!   \n",
            "#!#/bin/sh\n",
            "#!/bin/sh",
            "#!bin/sh\n",
            "#!/etc/hosts\n",
            "#!/bin\n",
            &long,
            &on_a_script,
        ] {
            let bin = scratch.sub("bin");
            let file = bin.join("claude");
            let _ = fs::remove_file(&file);
            gate::write_executable(&file, content);
            let start = start(&invocation("claude", &text(&bin), ""));
            assert!(
                matches!(&start, Start::Thrown(m) if m == "spawn ENOEXEC"),
                "{content}: {start:?}"
            );
        }
    }

    /// What the kernel of macOS runs, or reports an error for itself.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_file_the_kernel_takes_is_started_or_gets_its_own_error_on_macos() {
        let scratch = Scratch::new();
        let bin = scratch.path().join("bin");
        for content in [
            "#!/bin/sh\n",
            "#!  /bin/sh  -e\n",
            "#!/bin/sh # a comment\n",
            "#!/usr/bin/env sh\n",
        ] {
            gate::write_executable(&bin.join("claude"), content);
            let path = format!("{}:/usr/bin:/bin", text(&bin));
            let output = output_of(start(&invocation("claude", &path, "")));
            assert!(output.status.success(), "{content}");
        }
        fs::remove_file(bin.join("claude")).unwrap();
        // A thin file and a fat one, which a copy could not stand for: a system file stops running once it is moved.
        assert!(!kernel_may_refuse(
            std::env::current_exe().unwrap().to_str().unwrap()
        ));
        assert!(!kernel_may_refuse("/bin/echo"));
        gate::write_executable(&bin.join("claude"), "#!/no/such/program\n");
        assert_eq!(
            failed(&start(&invocation("claude", &text(&bin), ""))),
            "spawn claude ENOENT"
        );
        fs::remove_file(bin.join("claude")).unwrap();
        gate::write_executable(&bin.join("claude"), "#!/etc/hosts/program\n");
        match start(&invocation("claude", &text(&bin), "")) {
            Start::Thrown(message) => assert_eq!(message, "spawn ENOTDIR"),
            other => panic!("not what spawn throws: {other:?}"),
        }
    }

    /// A file that may be run and not read cannot be looked at, so it is not proven to be a program.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_program_that_cannot_be_read_is_enoexec_on_macos() {
        use rustix::process::geteuid;
        if geteuid().is_root() {
            return;
        }
        let scratch = Scratch::new();
        let file = scratch.path().join("bin/claude");
        gate::write_executable(&file, "#!/bin/sh\n");
        fs::set_permissions(&file, fs::Permissions::from_mode(0o111)).unwrap();
        let start = start(&invocation(
            "claude",
            &text(&scratch.path().join("bin")),
            "",
        ));
        assert!(
            matches!(&start, Start::Thrown(m) if m == "spawn ENOEXEC"),
            "{start:?}"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_relative_path_is_taken_against_the_directory_of_the_child_on_macos() {
        let scratch = Scratch::new();
        gate::write_executable(&scratch.path().join("good/claude"), WITNESS);
        for (program, path) in [
            ("./claude", "/usr/bin"),
            ("claude", ""),
            ("claude", ".:/usr/bin"),
            ("claude", "/no/such:rel"),
        ] {
            let start = start(&invocation(program, path, ""));
            assert!(
                matches!(start, Start::Failed(_)),
                "{program} on {path}: {start:?}"
            );
        }
        let good_first = format!("{}:.", text(&scratch.path().join("good")));
        assert!(
            output_of(start(&invocation("claude", &good_first, "")))
                .status
                .success()
        );
    }

    #[test]
    fn the_child_gets_its_words_its_directory_closed_stdin_and_two_pipes() {
        let scratch = Scratch::new();
        gate::write_executable(&scratch.path().join("bin/claude"), WITNESS);
        let work = scratch.path().join("work");
        fs::create_dir_all(&work).unwrap();
        let path = format!("{}:/usr/bin:/bin", text(&scratch.path().join("bin")));
        let output = output_of(start(&invocation("claude", &path, &text(&work))));
        let real = fs::canonicalize(&work).unwrap();
        assert_eq!(
            String::from_utf8(output.stdout).unwrap(),
            format!("-p a b|{}\nstdin-is-the-null-device\n", real.display())
        );
        assert_eq!(output.stderr, b"on stderr\n");
    }

    #[test]
    fn the_child_is_told_the_name_as_given() {
        let scratch = Scratch::new();
        let bin = scratch.path().join("bin");
        fs::create_dir_all(&bin).unwrap();
        std::os::unix::fs::symlink("/bin/sh", bin.join("claude")).unwrap();
        let mut given = invocation("claude", &text(&bin), "");
        given.args = vec!["-c".to_owned(), "echo \"$0\"".to_owned()];
        let output = output_of(start(&given));
        assert_eq!(output.stdout, b"claude\n");
    }

    #[test]
    fn the_child_runs_with_only_the_environment_it_was_given() {
        let scratch = Scratch::new();
        gate::write_executable(
            &scratch.path().join("bin/claude"),
            "#!/bin/sh\n/usr/bin/env\n",
        );
        let mut given = invocation("claude", &text(&scratch.path().join("bin")), "");
        given.env.insert("ONLY_THIS".to_owned(), "1".to_owned());
        let stdout = String::from_utf8(output_of(start(&given)).stdout).unwrap();
        // The names a shell adds by itself.
        let mut names: Vec<_> = stdout
            .lines()
            .filter_map(|line| line.split_once('=').map(|(name, _)| name))
            .filter(|name| !["PWD", "_", "SHLVL", "OLDPWD"].contains(name))
            .collect();
        names.sort_unstable();
        assert_eq!(names, ["ONLY_THIS", "PATH"]);
    }

    #[test]
    fn an_empty_working_directory_is_that_of_the_caller() {
        let scratch = Scratch::new();
        gate::write_executable(&scratch.path().join("bin/claude"), "#!/bin/sh\npwd -P\n");
        let path = format!("{}:/usr/bin:/bin", text(&scratch.path().join("bin")));
        let output = output_of(start(&invocation("claude", &path, "")));
        let own = fs::canonicalize(std::env::current_dir().unwrap()).unwrap();
        assert_eq!(
            String::from_utf8(output.stdout).unwrap().trim_end(),
            own.to_str().unwrap()
        );
    }

    #[test]
    fn the_child_stays_in_the_process_group_of_the_caller() {
        let scratch = Scratch::new();
        gate::write_executable(
            &scratch.path().join("bin/claude"),
            "#!/bin/sh\nread nothing\n",
        );
        let start = start(&invocation(
            "claude",
            &text(&scratch.path().join("bin")),
            "",
        ));
        let Start::Started(mut child) = start else {
            panic!("not started: {start:?}")
        };
        let pid = Pid::from_child(&child);
        assert_eq!(getpgid(Some(pid)).unwrap(), getpgrp());
        child.wait().unwrap();
    }
}
