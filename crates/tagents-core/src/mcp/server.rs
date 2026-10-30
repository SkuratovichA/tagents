//! The loop: reads requests, answers the ones that are quick on the reading thread, runs every `tools/call` on a thread of its own, and ends when its client does.
//!
//! It is `packages/mcp/src/server.ts` and `main.ts` on top of the SDK's `Server` and stdio transport, and it is generic over the tools it serves: it knows `initialize`, `ping`, `tools/list`, `tools/call` and `notifications/cancelled`, and nothing of verbs or programs.

use std::collections::HashMap;
use std::io::{self, Read};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use serde::Serialize;
use serde_json::{Map, Value, json};

use super::rpc::{
    CallResult, Framer, INTERNAL_ERROR, INVALID_PARAMS, Id, Incoming, METHOD_NOT_FOUND,
    Notification, Out, Request, ToolEntry, parse,
};

/// What the server is called, and the version it tells: the workspace's, which the node server's constant `0.1.0` never followed.
pub const SERVER_NAME: &str = "tagents";
pub const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");

/// The protocol versions the SDK supports (`SUPPORTED_PROTOCOL_VERSIONS` of `@modelcontextprotocol/sdk/types.js`), newest first. A client that asks for another gets the first. `tests/rust-mcp-parity.sh` reads the list from the SDK and pins this one to it.
pub const PROTOCOL_VERSIONS: [&str; 5] = [
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
    "2024-10-07",
];

/// What the server waits, beyond the grace a stopped call has, for the calls to be gone before it ends anyway.
pub const SHUTDOWN_MARGIN: Duration = Duration::from_millis(2000);

fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Says that a call has to stop: the client cancelled its request, or the server is closing. It is the SDK's `AbortSignal`.
#[derive(Clone, Default)]
pub struct Stop(Arc<Mutex<StopState>>);

#[derive(Default)]
struct StopState {
    stopped: bool,
    watchers: Vec<Box<dyn FnOnce() + Send>>,
}

impl Stop {
    /// Idempotent. The watchers run on the calling thread, once each, outside the lock.
    pub fn stop(&self) {
        let watchers = {
            let mut state = locked(&self.0);
            state.stopped = true;
            std::mem::take(&mut state.watchers)
        };
        for watcher in watchers {
            watcher();
        }
    }

    pub fn is_stopped(&self) -> bool {
        locked(&self.0).stopped
    }

    /// Runs `watcher` when the stop comes, at once when it has come.
    pub fn watch(&self, watcher: impl FnOnce() + Send + 'static) {
        let mut state = locked(&self.0);
        if state.stopped {
            drop(state);
            watcher();
        } else {
            state.watchers.push(Box::new(watcher));
        }
    }
}

/// What the loop needs of a server's tools; the verbs behind them are none of its business.
pub trait Tools: Send + Sync + 'static {
    fn list(&self) -> Vec<ToolEntry>;
    /// `None`: no tool of that name. `stop` says when the client cancels the request or the server closes.
    fn call(&self, name: &str, args: &Map<String, Value>, stop: &Stop) -> Option<CallResult>;
}

/// The calls in flight. A call is cancelled by the id its request had, and stopped by the ending whatever its id was, so the two are kept apart: an id can be sent twice while the first request is running, and the later one is the one a cancellation names.
#[derive(Default)]
struct Registry {
    state: Mutex<RegistryState>,
    emptied: Condvar,
}

#[derive(Default)]
struct RegistryState {
    next: u64,
    calls: HashMap<u64, Entry>,
    by_id: HashMap<Id, u64>,
    /// The server is ending: a call that begins now is stopped before it starts.
    closing: bool,
}

struct Entry {
    id: Id,
    stop: Stop,
    /// The client cancelled the request: the call is stopped and gets no response.
    cancelled: bool,
}

impl Registry {
    fn begin(&self, id: &Id) -> (u64, Stop) {
        let mut state = locked(&self.state);
        let serial = state.next;
        state.next += 1;
        let stop = Stop::default();
        if state.closing {
            stop.stop();
        }
        state.calls.insert(
            serial,
            Entry {
                id: id.clone(),
                stop: stop.clone(),
                cancelled: false,
            },
        );
        state.by_id.insert(id.clone(), serial);
        (serial, stop)
    }

    /// `notifications/cancelled`. The SDK ignores an id that is falsy, one it does not know, and one whose request has finished.
    fn cancel(&self, id: &Id) {
        if id.is_falsy() {
            return;
        }
        let stop = {
            let mut state = locked(&self.state);
            let Some(serial) = state.by_id.get(id).copied() else {
                return;
            };
            let Some(entry) = state.calls.get_mut(&serial) else {
                return;
            };
            entry.cancelled = true;
            entry.stop.clone()
        };
        stop.stop();
    }

    /// Says whether the call's request is to be answered, and closes the request to cancellation: the flag is read and the id released under one lock, so a cancellation lands either before (no answer) or after (nothing to cancel). A call that is to be answered stays in the registry until `finish`, so that an ending waits for its answer to be written, and not only for the call to be over.
    fn settle(&self, serial: u64) -> bool {
        let answered = {
            let mut state = locked(&self.state);
            let Some(entry) = state.calls.get(&serial) else {
                return false;
            };
            let (id, answered) = (entry.id.clone(), !entry.cancelled);
            if state.by_id.get(&id) == Some(&serial) {
                state.by_id.remove(&id);
            }
            answered
        };
        if !answered {
            self.finish(serial);
        }
        answered
    }

    /// Takes the call out of the registry.
    fn finish(&self, serial: u64) {
        let mut state = locked(&self.state);
        state.calls.remove(&serial);
        if state.calls.is_empty() {
            self.emptied.notify_all();
        }
    }

    fn stop_all(&self) {
        let stops: Vec<Stop> = {
            let mut state = locked(&self.state);
            state.closing = true;
            state
                .calls
                .values()
                .map(|entry| entry.stop.clone())
                .collect()
        };
        for stop in stops {
            stop.stop();
        }
    }

    /// Returns when no call is in flight, or when `timeout` has passed.
    fn wait_empty(&self, timeout: Duration) {
        let state = locked(&self.state);
        let _ = self
            .emptied
            .wait_timeout_while(state, timeout, |state| !state.calls.is_empty());
    }
}

#[derive(Clone, Copy)]
pub struct Config {
    /// What a stopped call has to leave on SIGTERM before it is killed.
    pub kill_grace: Duration,
    pub shutdown_margin: Duration,
}

pub struct Server {
    tools: Arc<dyn Tools>,
    out: Out,
    calls: Registry,
    ending: AtomicBool,
    config: Config,
    /// What leaves the process once an ending is done; the tests put something else here.
    exit: Box<dyn Fn() + Send + Sync>,
}

#[derive(Serialize)]
struct Initialized {
    #[serde(rename = "protocolVersion")]
    protocol_version: &'static str,
    capabilities: Value,
    #[serde(rename = "serverInfo")]
    server_info: ServerInfo,
}

#[derive(Serialize)]
struct ServerInfo {
    name: &'static str,
    version: &'static str,
}

#[derive(Serialize)]
struct Listed {
    tools: Vec<ToolEntry>,
}

/// A reason a request's params are refused, in the words of the answer.
fn invalid(reason: &str) -> String {
    format!("Invalid params: {reason}")
}

impl Server {
    pub fn new(
        tools: Arc<dyn Tools>,
        out: Out,
        config: Config,
        exit: impl Fn() + Send + Sync + 'static,
    ) -> Arc<Server> {
        Arc::new(Server {
            tools,
            out,
            calls: Registry::default(),
            ending: AtomicBool::new(false),
            config,
            exit: Box::new(exit),
        })
    }

    /// Reads `input` until it ends, answering as it goes, then ends the server: whatever the calls in flight started is stopped, they answer, and the function returns. The caller leaves the process.
    pub fn serve(self: &Arc<Self>, mut input: impl Read) {
        let mut framer = Framer::default();
        let mut chunk = vec![0u8; 64 * 1024];
        'reading: loop {
            let read = match input.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            };
            // The SDK gives up on a stream whose unfinished line outgrows its buffer.
            if framer.push(&chunk[..read]).is_err() {
                break;
            }
            while let Some(line) = framer.next_line() {
                if let Some(message) = parse(&line)
                    && self.dispatch(message).is_err()
                {
                    break 'reading;
                }
            }
        }
        self.end();
    }

    /// The server ends when its client does: stdin closed, a signal, or an output nobody reads. The calls in flight are stopped first, because the client that asked for them is gone and nobody else would; each answers, and the function waits until they are gone or the margin is over. Ending twice is one ending: the second caller waits with the first.
    pub fn end(&self) {
        if !self.ending.swap(true, Ordering::SeqCst) {
            self.calls.stop_all();
        }
        self.calls
            .wait_empty(self.config.kill_grace + self.config.shutdown_margin);
    }

    /// An ending that leaves the process too, for a thread that is not the reading one.
    pub fn end_and_exit(&self) {
        self.end();
        (self.exit)();
    }

    fn dispatch(self: &Arc<Self>, message: Incoming) -> io::Result<()> {
        match message {
            Incoming::Request(request) => self.request(request),
            Incoming::Notification(notification) => {
                self.notification(&notification);
                Ok(())
            }
        }
    }

    fn notification(&self, notification: &Notification) {
        if notification.method != "notifications/cancelled" {
            return;
        }
        // `params` is required and `requestId` is an id when it is there; anything else is a notification the SDK drops.
        let Some(params) = &notification.params else {
            return;
        };
        if !matches!(params.get("reason"), None | Some(Value::String(_))) {
            return;
        }
        let Some(id) = params.get("requestId").and_then(Id::from_json) else {
            return;
        };
        self.calls.cancel(&id);
    }

    fn request(self: &Arc<Self>, request: Request) -> io::Result<()> {
        let Request { id, method, params } = request;
        match method.as_str() {
            "initialize" => match initialize(params.as_ref()) {
                Ok(result) => self.out.success(&id, result),
                Err(reason) => self.out.failure(&id, INVALID_PARAMS, &invalid(&reason)),
            },
            "ping" => self.out.success(&id, json!({})),
            "tools/list" => match params.as_ref().and_then(|p| p.get("cursor")) {
                None | Some(Value::String(_)) => self.out.success(
                    &id,
                    Listed {
                        tools: self.tools.list(),
                    },
                ),
                Some(_) => {
                    self.out
                        .failure(&id, INVALID_PARAMS, &invalid("cursor must be a string"))
                }
            },
            "tools/call" => match call_params(params) {
                Ok((name, args)) => self.start_call(id, name, args),
                Err(reason) => self.out.failure(&id, INVALID_PARAMS, &invalid(reason)),
            },
            _ => self.out.failure(&id, METHOD_NOT_FOUND, "Method not found"),
        }
    }

    /// Runs the call on a thread of its own, so that a slow call never holds a fast one, and answers when it ends.
    fn start_call(
        self: &Arc<Self>,
        id: Id,
        name: String,
        args: Map<String, Value>,
    ) -> io::Result<()> {
        let (serial, stop) = self.calls.begin(&id);
        let server = Arc::clone(self);
        let reply_id = id.clone();
        let spawned = std::thread::Builder::new()
            .name("tagents-call".into())
            .spawn(move || {
                let result = server.tools.call(&name, &args, &stop);
                if !server.calls.settle(serial) {
                    return;
                }
                let sent = match result {
                    Some(result) => server.out.success(&reply_id, result),
                    None => server.out.failure(
                        &reply_id,
                        INVALID_PARAMS,
                        &format!("MCP error {INVALID_PARAMS}: unknown tool {name}"),
                    ),
                };
                server.calls.finish(serial);
                if sent.is_err() {
                    server.end_and_exit();
                }
            });
        match spawned {
            Ok(_) => Ok(()),
            Err(e) => {
                self.calls.finish(serial);
                self.out.failure(
                    &id,
                    INTERNAL_ERROR,
                    &format!("could not start a thread for the call: {e}"),
                )
            }
        }
    }
}

/// The result of `initialize`: the version the client asked for when the SDK supports it, the newest otherwise.
fn initialize(params: Option<&Map<String, Value>>) -> Result<Initialized, String> {
    let params = params.ok_or("params are required")?;
    let requested = params
        .get("protocolVersion")
        .and_then(Value::as_str)
        .ok_or("protocolVersion must be a string")?;
    if !params.get("capabilities").is_some_and(Value::is_object) {
        return Err("capabilities must be an object".into());
    }
    let client = params
        .get("clientInfo")
        .and_then(Value::as_object)
        .ok_or("clientInfo must be an object")?;
    if !client.get("name").is_some_and(Value::is_string)
        || !client.get("version").is_some_and(Value::is_string)
    {
        return Err("clientInfo needs a name and a version, both strings".into());
    }
    let protocol_version = PROTOCOL_VERSIONS
        .into_iter()
        .find(|v| *v == requested)
        .unwrap_or(PROTOCOL_VERSIONS[0]);
    Ok(Initialized {
        protocol_version,
        capabilities: json!({"tools": {}}),
        server_info: ServerInfo {
            name: SERVER_NAME,
            version: SERVER_VERSION,
        },
    })
}

/// The tool a `tools/call` names and its arguments; a call without `arguments` has none.
fn call_params(
    params: Option<Map<String, Value>>,
) -> Result<(String, Map<String, Value>), &'static str> {
    let mut params = params.ok_or("params are required")?;
    let Some(Value::String(name)) = params.remove("name") else {
        return Err("name must be a string");
    };
    match params.remove("arguments") {
        None => Ok((name, Map::new())),
        Some(Value::Object(args)) => Ok((name, args)),
        Some(_) => Err("arguments must be an object"),
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::sync::atomic::AtomicUsize;
    use std::sync::mpsc;
    use std::time::Instant;

    use super::*;

    /// What the fake tools do, by name: `echo` answers its arguments, `slow` waits for its stop and says so, `quick` answers at once.
    struct Fake {
        started: mpsc::SyncSender<String>,
        counter: AtomicUsize,
    }

    impl Tools for Fake {
        fn list(&self) -> Vec<ToolEntry> {
            vec![ToolEntry {
                name: "echo".into(),
                description: "Echoes.".into(),
                input_schema: json!({"type": "object"}),
                annotations: json!({"readOnlyHint": true}),
            }]
        }

        fn call(&self, name: &str, args: &Map<String, Value>, stop: &Stop) -> Option<CallResult> {
            self.counter.fetch_add(1, Ordering::SeqCst);
            match name {
                "echo" => Some(CallResult::text(
                    Value::Object(args.clone()).to_string(),
                    false,
                )),
                "slow" => {
                    let (tx, rx) = mpsc::channel();
                    stop.watch(move || {
                        let _ = tx.send(());
                    });
                    let _ = self.started.send(name.to_owned());
                    let _ = rx.recv();
                    Some(CallResult::text("stopped".into(), true))
                }
                _ => None,
            }
        }
    }

    /// What the server wrote, and how long each write takes.
    #[derive(Clone, Default)]
    struct Lines(Arc<(Mutex<Vec<u8>>, Condvar)>, Duration);

    impl Write for Lines {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            std::thread::sleep(self.1);
            locked(&self.0.0).extend_from_slice(buf);
            self.0.1.notify_all();
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl Lines {
        fn slow(delay: Duration) -> Lines {
            Lines(Arc::default(), delay)
        }

        /// The lines written so far, once there are `count` of them (or after five seconds, with what there is).
        fn wait_for(&self, count: usize) -> Vec<String> {
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut bytes = locked(&self.0.0);
            while bytes.iter().filter(|b| **b == b'\n').count() < count {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    break;
                }
                bytes = self
                    .0
                    .1
                    .wait_timeout(bytes, left)
                    .unwrap_or_else(PoisonError::into_inner)
                    .0;
            }
            String::from_utf8_lossy(&bytes)
                .lines()
                .map(str::to_owned)
                .collect()
        }
    }

    /// Bytes fed to the server a piece at a time; closing the sender is the end of the input.
    struct Feed(mpsc::Receiver<Vec<u8>>);

    impl Read for Feed {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            match self.0.recv() {
                Ok(bytes) => {
                    buf[..bytes.len()].copy_from_slice(&bytes);
                    Ok(bytes.len())
                }
                Err(_) => Ok(0),
            }
        }
    }

    struct Rig {
        server: Arc<Server>,
        lines: Lines,
        feed: mpsc::Sender<Vec<u8>>,
        input: Option<Feed>,
        started: mpsc::Receiver<String>,
        fake: Arc<Fake>,
    }

    impl Rig {
        fn new() -> Rig {
            Rig::writing_to(Lines::default(), Duration::from_millis(50))
        }

        fn writing_to(lines: Lines, shutdown_margin: Duration) -> Rig {
            let (started_tx, started) = mpsc::sync_channel(16);
            let fake = Arc::new(Fake {
                started: started_tx,
                counter: AtomicUsize::new(0),
            });
            let (feed, rx) = mpsc::channel();
            let config = Config {
                kill_grace: Duration::from_millis(50),
                shutdown_margin,
            };
            let server = Server::new(
                Arc::clone(&fake) as Arc<dyn Tools>,
                Out::new(lines.clone()),
                config,
                || {},
            );
            Rig {
                server,
                lines,
                feed,
                input: Some(Feed(rx)),
                started,
                fake,
            }
        }

        fn send(&self, line: &str) {
            self.feed.send(format!("{line}\n").into_bytes()).unwrap();
        }

        /// Runs the loop on a thread; the handle returns when the server has ended.
        fn run(&mut self) -> std::thread::JoinHandle<()> {
            let server = Arc::clone(&self.server);
            let input = self.input.take().unwrap();
            std::thread::spawn(move || server.serve(input))
        }
    }

    fn value(line: &str) -> Value {
        serde_json::from_str(line).unwrap()
    }

    #[test]
    fn initialize_answers_a_supported_version_as_asked_and_the_newest_otherwise() {
        let mut rig = Rig::new();
        let ended = rig.run();
        let initialize = |id: u32, version: &str| {
            format!(
                r#"{{"jsonrpc":"2.0","id":{id},"method":"initialize","params":{{"protocolVersion":"{version}","capabilities":{{}},"clientInfo":{{"name":"t","version":"1"}}}}}}"#
            )
        };
        let asked: Vec<&str> = PROTOCOL_VERSIONS
            .iter()
            .copied()
            .chain(["1999-01-01"])
            .collect();
        let answered: Vec<&str> = PROTOCOL_VERSIONS
            .iter()
            .copied()
            .chain([PROTOCOL_VERSIONS[0]])
            .collect();
        for (i, version) in asked.iter().enumerate() {
            rig.send(&initialize(i as u32, version));
        }
        let lines = rig.lines.wait_for(6);
        for (i, version) in answered.iter().enumerate() {
            assert_eq!(
                lines[i],
                format!(
                    r#"{{"result":{{"protocolVersion":"{version}","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"tagents","version":"{SERVER_VERSION}"}}}},"jsonrpc":"2.0","id":{i}}}"#
                ),
            );
        }
        drop(rig.feed);
        ended.join().unwrap();
    }

    #[test]
    fn ping_lists_and_unknown_methods_answer_in_the_sdks_words() {
        let mut rig = Rig::new();
        let ended = rig.run();
        rig.send(r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#);
        rig.send(r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#);
        rig.send(r#"{"jsonrpc":"2.0","id":"x","method":"resources/list"}"#);
        let lines = rig.lines.wait_for(3);
        assert_eq!(lines[0], r#"{"result":{},"jsonrpc":"2.0","id":1}"#);
        assert_eq!(
            lines[1],
            r#"{"result":{"tools":[{"name":"echo","description":"Echoes.","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}}]},"jsonrpc":"2.0","id":2}"#,
        );
        assert_eq!(
            lines[2],
            r#"{"jsonrpc":"2.0","id":"x","error":{"code":-32601,"message":"Method not found"}}"#
        );
        drop(rig.feed);
        ended.join().unwrap();
    }

    #[test]
    fn a_call_answers_with_the_tools_result_and_an_unknown_tool_with_the_sdks_error() {
        let mut rig = Rig::new();
        let ended = rig.run();
        rig.send(r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"a":1}}}"#);
        rig.send(r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nope"}}"#);
        rig.send(r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo"}}"#);
        let mut lines = rig.lines.wait_for(3);
        lines.sort();
        assert_eq!(
            lines[0],
            r#"{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"MCP error -32602: unknown tool nope"}}"#
        );
        assert_eq!(
            lines[1],
            r#"{"result":{"content":[{"type":"text","text":"{\"a\":1}"}],"isError":false},"jsonrpc":"2.0","id":1}"#
        );
        assert_eq!(
            lines[2],
            r#"{"result":{"content":[{"type":"text","text":"{}"}],"isError":false},"jsonrpc":"2.0","id":3}"#
        );
        drop(rig.feed);
        ended.join().unwrap();
    }

    #[test]
    fn params_the_methods_cannot_use_are_answered_invalid_not_ignored() {
        let mut rig = Rig::new();
        let ended = rig.run();
        for (id, method, params) in [
            (1, "initialize", ""),
            (
                2,
                "initialize",
                r#","params":{"protocolVersion":1,"capabilities":{},"clientInfo":{"name":"t","version":"1"}}"#,
            ),
            (
                3,
                "initialize",
                r#","params":{"protocolVersion":"x","capabilities":{},"clientInfo":{"name":"t"}}"#,
            ),
            (4, "tools/call", ""),
            (5, "tools/call", r#","params":{"arguments":{}}"#),
            (
                6,
                "tools/call",
                r#","params":{"name":"echo","arguments":[]}"#,
            ),
            (7, "tools/list", r#","params":{"cursor":3}"#),
        ] {
            rig.send(&format!(
                r#"{{"jsonrpc":"2.0","id":{id},"method":"{method}"{params}}}"#
            ));
        }
        for (i, line) in rig.lines.wait_for(7).iter().enumerate() {
            let answer = value(line);
            assert_eq!(answer["id"], i + 1, "{line}");
            assert_eq!(answer["error"]["code"], -32602, "{line}");
            assert!(
                answer["error"]["message"]
                    .as_str()
                    .is_some_and(|m| m.starts_with("Invalid params: ")),
                "{line}"
            );
        }
        drop(rig.feed);
        ended.join().unwrap();
    }

    #[test]
    fn what_the_sdk_ignores_gets_no_answer_and_nothing_is_written() {
        let mut rig = Rig::new();
        let ended = rig.run();
        rig.send("not json");
        rig.send(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#);
        rig.send(r#"{"jsonrpc":"2.0","method":"notifications/never-heard-of"}"#);
        rig.send(r#"{"jsonrpc":"2.0","id":1,"result":{}}"#);
        rig.send(r#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#);
        // The ping is the only message that was answered, and it comes last.
        assert_eq!(
            rig.lines.wait_for(1),
            [r#"{"result":{},"jsonrpc":"2.0","id":9}"#]
        );
        drop(rig.feed);
        ended.join().unwrap();
        assert_eq!(rig.lines.wait_for(0).len(), 1);
    }

    #[test]
    fn a_last_line_without_a_newline_is_never_processed() {
        let mut rig = Rig::new();
        let ended = rig.run();
        rig.feed
            .send(br#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.to_vec())
            .unwrap();
        drop(rig.feed);
        ended.join().unwrap();
        assert!(rig.lines.wait_for(0).is_empty());
    }

    #[test]
    fn a_cancelled_request_is_stopped_and_never_answered() {
        let mut rig = Rig::new();
        let ended = rig.run();
        rig.send(r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"slow"}}"#);
        assert_eq!(
            rig.started.recv_timeout(Duration::from_secs(5)).as_deref(),
            Ok("slow")
        );
        rig.send(r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"changed my mind"}}"#);
        rig.send(r#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#);
        assert_eq!(
            rig.lines.wait_for(1),
            [r#"{"result":{},"jsonrpc":"2.0","id":8}"#]
        );
        drop(rig.feed);
        ended.join().unwrap();
        assert_eq!(rig.lines.wait_for(0).len(), 1);
    }

    #[test]
    fn ids_that_are_falsy_or_of_another_type_cannot_be_cancelled_by_another_spelling() {
        let mut rig = Rig::new();
        let ended = rig.run();
        rig.send(r#"{"jsonrpc":"2.0","id":0,"method":"tools/call","params":{"name":"slow"}}"#);
        rig.send(r#"{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":"slow"}}"#);
        rig.started.recv_timeout(Duration::from_secs(5)).unwrap();
        rig.started.recv_timeout(Duration::from_secs(5)).unwrap();
        // 0 is falsy, and the number 1 is not the string "1".
        rig.send(
            r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":0}}"#,
        );
        rig.send(
            r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#,
        );
        rig.send(r#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#);
        assert_eq!(
            rig.lines.wait_for(1),
            [r#"{"result":{},"jsonrpc":"2.0","id":8}"#]
        );
        // Closing the input stops both, and they answer.
        drop(rig.feed);
        ended.join().unwrap();
        let mut lines = rig.lines.wait_for(3);
        lines.sort();
        assert_eq!(lines.len(), 3, "{lines:?}");
        assert!(
            lines[0].contains(r#""id":"1""#) && lines[0].contains(r#"stopped"#),
            "{lines:?}"
        );
        assert!(
            lines[1].contains(r#""id":0"#) && lines[1].contains(r#"stopped"#),
            "{lines:?}"
        );
    }

    #[test]
    fn a_cancellation_that_arrives_after_the_answer_changes_nothing() {
        let mut rig = Rig::new();
        let ended = rig.run();
        rig.send(r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo"}}"#);
        assert_eq!(rig.lines.wait_for(1).len(), 1);
        rig.send(
            r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#,
        );
        rig.send(r#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#);
        assert_eq!(rig.lines.wait_for(2).len(), 2);
        drop(rig.feed);
        ended.join().unwrap();
    }

    #[test]
    fn the_input_ending_stops_the_calls_in_flight_and_they_answer() {
        let mut rig = Rig::new();
        let ended = rig.run();
        rig.send(r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow"}}"#);
        rig.send(r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow"}}"#);
        rig.started.recv_timeout(Duration::from_secs(5)).unwrap();
        rig.started.recv_timeout(Duration::from_secs(5)).unwrap();
        drop(rig.feed);
        ended.join().unwrap();
        let lines = rig.lines.wait_for(2);
        assert_eq!(lines.len(), 2);
        assert!(lines.iter().all(|l| l.contains("stopped")));
        assert_eq!(rig.fake.counter.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn the_ending_returns_only_after_the_answers_of_the_calls_it_stopped_are_written() {
        // The process leaves when `serve` returns, so an answer still being written then is lost: the write takes longer than the call, and nothing is waited for after the join.
        // The margin is long so that a loaded runner cannot end the wait before the two serialised writes are done; the join returns as soon as both are, and the assertion fails at once if it returned earlier.
        let mut rig = Rig::writing_to(
            Lines::slow(Duration::from_millis(40)),
            Duration::from_secs(10),
        );
        let ended = rig.run();
        rig.send(r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow"}}"#);
        rig.send(r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow"}}"#);
        rig.started.recv_timeout(Duration::from_secs(5)).unwrap();
        rig.started.recv_timeout(Duration::from_secs(5)).unwrap();
        drop(rig.feed);
        ended.join().unwrap();
        assert_eq!(rig.lines.wait_for(0).len(), 2);
    }

    #[test]
    fn a_duplicate_id_is_cancelled_through_the_later_request_and_the_earlier_one_still_answers() {
        let mut rig = Rig::new();
        let ended = rig.run();
        rig.send(r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"slow"}}"#);
        rig.started.recv_timeout(Duration::from_secs(5)).unwrap();
        rig.send(r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"slow"}}"#);
        rig.started.recv_timeout(Duration::from_secs(5)).unwrap();
        rig.send(
            r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}"#,
        );
        rig.send(r#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#);
        assert_eq!(
            rig.lines.wait_for(1),
            [r#"{"result":{},"jsonrpc":"2.0","id":6}"#]
        );
        drop(rig.feed);
        ended.join().unwrap();
        // The later request was cancelled and is not answered; the earlier one was stopped by the ending and is.
        let lines = rig.lines.wait_for(2);
        assert_eq!(lines.len(), 2, "{lines:?}");
        assert!(
            lines[1].contains(r#""id":5"#) && lines[1].contains("stopped"),
            "{lines:?}"
        );
    }

    #[test]
    fn a_failing_output_ends_the_server_through_the_exit_it_was_given() {
        struct Broken;
        impl Write for Broken {
            fn write(&mut self, _: &[u8]) -> io::Result<usize> {
                Err(io::ErrorKind::BrokenPipe.into())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let (started_tx, _started) = mpsc::sync_channel(16);
        let fake = Arc::new(Fake {
            started: started_tx,
            counter: AtomicUsize::new(0),
        });
        let (exited_tx, exited) = mpsc::channel();
        let config = Config {
            kill_grace: Duration::from_millis(50),
            shutdown_margin: Duration::from_millis(50),
        };
        let server = Server::new(fake, Out::new(Broken), config, move || {
            let _ = exited_tx.send(());
        });
        let (feed, rx) = mpsc::channel::<Vec<u8>>();
        let reading = Arc::clone(&server);
        let ended = std::thread::spawn(move || reading.serve(Feed(rx)));
        feed.send(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\"}}\n".to_vec()).unwrap();
        // The call thread cannot write its answer: it ends the server and leaves.
        assert_eq!(exited.recv_timeout(Duration::from_secs(5)), Ok(()));
        drop(feed);
        ended.join().unwrap();
    }

    #[test]
    fn an_unfinished_line_longer_than_the_buffer_ends_the_server() {
        let mut rig = Rig::new();
        let ended = rig.run();
        rig.feed.send(vec![b'x'; 64 * 1024]).unwrap();
        for _ in 0..160 {
            if rig.feed.send(vec![b'x'; 64 * 1024]).is_err() {
                break;
            }
        }
        ended.join().unwrap();
    }

    #[test]
    fn ending_twice_is_one_ending() {
        let mut rig = Rig::new();
        let ended = rig.run();
        rig.send(r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow"}}"#);
        rig.started.recv_timeout(Duration::from_secs(5)).unwrap();
        let other = Arc::clone(&rig.server);
        let second = std::thread::spawn(move || other.end());
        rig.server.end();
        second.join().unwrap();
        drop(rig.feed);
        ended.join().unwrap();
        assert_eq!(rig.lines.wait_for(1).len(), 1);
    }

    #[test]
    fn a_call_that_begins_during_the_ending_is_stopped_before_it_starts() {
        let mut rig = Rig::new();
        let ended = rig.run();
        rig.server.end();
        rig.send(r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow"}}"#);
        // The fake registers for the stop, finds it come, and answers without anyone cancelling.
        assert_eq!(rig.lines.wait_for(1).len(), 1);
        drop(rig.feed);
        ended.join().unwrap();
    }
}
