//! The transcripts the sessions tools and the sessions verb are checked against: the two sessions every recorded fixture of the node CLI was made from.

use std::{
    fs,
    io::Write,
    path::Path,
    time::{Duration, UNIX_EPOCH},
};

/// `transcript()` in `packages/core/test/helpers.ts`: one meta turn, the prompt, padding past the 2000-byte floor, a superseded reply and the reply.
pub fn transcript(prompt: &str, reply: &str) -> String {
    let json = |s: &str| serde_json::to_string(s).unwrap();
    let pad = "x".repeat(2400);
    [
        r#"{"type":"user","isMeta":true,"message":{"content":"<command-name>/init</command-name>"}}"#.to_owned(),
        format!(r#"{{"type":"user","message":{{"content":{}}}}}"#, json(prompt)),
        format!(r#"{{"type":"system","subtype":"pad","note":"{pad}"}}"#),
        r#"{"type":"assistant","message":{"content":[{"type":"text","text":"first pass, superseded"}]}}"#.to_owned(),
        format!(r#"{{"type":"assistant","message":{{"content":[{{"type":"text","text":{}}}]}}}}"#, json(reply)),
        String::new(),
    ]
    .join("\n")
}

/// `seedSessions()` in `helpers.ts`: the two sessions every fixture was recorded from.
pub fn seed_sessions(claude_home: &Path) {
    for (slug, id, prompt, reply, at) in [
        (
            "-Users-demo-git-demo",
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "Fix the deploy script for the staging cluster",
            "Deploy script fixed and staging is green.",
            1_767_323_045, // 2026-01-02T03:04:05Z
        ),
        (
            "-Users-demo-git-other-repo",
            "ffffffff-1111-2222-3333-444444444444",
            "Собери сводку по топикам за неделю",
            "Сводка готова, отправил в «dev».",
            1_770_091_506, // 2026-02-03T04:05:06Z
        ),
    ] {
        let dir = claude_home.join("projects").join(slug);
        fs::create_dir_all(&dir).unwrap();
        let file = fs::File::create(dir.join(format!("{id}.jsonl"))).unwrap();
        (&file)
            .write_all(transcript(prompt, reply).as_bytes())
            .unwrap();
        file.set_modified(UNIX_EPOCH + Duration::from_secs(at))
            .unwrap();
    }
}
