//! What a start is made of that needs no process: the backend it picks, the lines it writes, the script a click runs and the host a notice names.

use std::os::unix::fs::symlink;

use super::*;
use crate::testing::gate::write_executable;

fn backend(os: &str, which: Backend) -> Result<&'static str, String> {
    let log: Arc<dyn Log> = Arc::new(RecordingLog::new());
    backend_for(os, which, log, "/app/T.app").map(|platform| platform.name)
}

#[test]
fn backend_none_is_a_reason_to_leave() {
    assert_eq!(
        backend("darwin", Backend::None),
        Err("backend none: nothing to post".to_owned())
    );
    assert_eq!(
        backend("linux", Backend::None),
        Err("backend none: nothing to post".to_owned())
    );
}

#[test]
fn a_system_with_no_backend_is_a_reason_to_leave() {
    for which in [Backend::Auto, Backend::Macos] {
        assert_eq!(
            backend("linux", which),
            Err("no notification backend for linux yet".to_owned())
        );
    }
    assert_eq!(
        backend("linux", Backend::Log),
        Ok("log"),
        "the log backend runs anywhere"
    );
    assert_eq!(backend("darwin", Backend::Auto), Ok("macos"));
    assert_eq!(backend("darwin", Backend::Log), Ok("log"));
}

#[test]
fn leaving_says_why_releases_the_lock_and_exits_0() {
    let (rig, _messages) = Rig::new();
    let code = leave("backend none: nothing to post", &rig.lock, &rig.log);
    assert_eq!(code, ExitCode::SUCCESS);
    assert_eq!(rig.log.lines(), ["backend none: nothing to post; exiting"]);
    assert!(!rig.lock_held());
}

#[test]
fn started_is_the_line_that_says_what_is_in_force() {
    let log = RecordingLog::new();
    for state in ["found", "not found", "invalid"] {
        log_started(&log, 4242, "log", "/c/plugins/notify.toml", state);
    }
    assert_eq!(
        log.lines(),
        [
            "started pid 4242 backend log options /c/plugins/notify.toml (found)",
            "started pid 4242 backend log options /c/plugins/notify.toml (not found)",
            "started pid 4242 backend log options /c/plugins/notify.toml (invalid)"
        ]
    );
}

fn env(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs
        .iter()
        .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
        .collect()
}

/// An executable file `name` in a new directory `bin` of the scratch directory, and the directory.
fn program(scratch: &Scratch, bin: &str, name: &str) -> PathBuf {
    let dir = scratch.sub(bin);
    let file = dir.join(name);
    write_executable(&file, "#!/bin/sh\n");
    dir
}

#[test]
fn the_override_of_the_script_wins_and_an_empty_one_is_none() {
    let scratch = Scratch::new();
    let bin = program(&scratch, "bin", "tagents");
    let path = bin.to_string_lossy().into_owned();
    assert_eq!(
        tagents_script(&env(&[
            ("TA_NOTIFY_TAGENTS", "/x/tagents"),
            ("PATH", &path)
        ])),
        "/x/tagents"
    );
    assert_eq!(
        tagents_script(&env(&[("TA_NOTIFY_TAGENTS", ""), ("PATH", &path)])),
        format!("{path}/tagents")
    );
}

#[test]
fn without_an_override_it_is_the_first_tagents_on_the_path_as_found() {
    let scratch = Scratch::new();
    let elsewhere = program(&scratch, "elsewhere", "tagents-real");
    let first = scratch.sub("first");
    symlink(elsewhere.join("tagents-real"), first.join("tagents")).unwrap();
    let second = program(&scratch, "second", "tagents");
    let path = format!("::{}:{}", first.display(), second.display());
    assert_eq!(
        tagents_script(&env(&[("PATH", &path)])),
        format!("{}/tagents", first.display()),
        "a symlink stays the symlink: the click runs the script the dashboard runs"
    );
}

#[test]
fn with_none_on_the_path_it_is_the_script_at_the_root_when_there_is_one_and_the_bare_name_when_not()
{
    let scratch = Scratch::new();
    let empty = scratch.sub("empty").to_string_lossy().into_owned();
    let checkout = scratch.sub("checkout");
    fs::write(checkout.join("tagents"), "#!/bin/sh\n").unwrap();
    let release = scratch.sub("release");
    assert_eq!(
        script_on(Some(&empty), Some(&checkout)),
        format!("{}/tagents", checkout.display())
    );
    assert_eq!(
        script_on(None, Some(&checkout)),
        format!("{}/tagents", checkout.display())
    );
    assert_eq!(script_on(Some(&empty), Some(&release)), "tagents");
    assert_eq!(script_on(Some(&empty), None), "tagents");
    assert_eq!(script_on(None, None), "tagents");
}

#[test]
fn the_path_wins_over_the_root() {
    let scratch = Scratch::new();
    let bin = program(&scratch, "bin", "tagents");
    let checkout = scratch.sub("checkout");
    fs::write(checkout.join("tagents"), "#!/bin/sh\n").unwrap();
    assert_eq!(
        script_on(Some(&bin.to_string_lossy()), Some(&checkout)),
        format!("{}/tagents", bin.display())
    );
}

#[test]
fn the_host_is_named() {
    assert!(!hostname().is_empty());
}
