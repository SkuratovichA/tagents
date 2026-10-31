//! The backends the daemon can start with and the choice between them: `pickPlatform` of `packages/notify/src/platform/index.ts`, the `log` notifier (`log.ts`) and the `unsupported` one (`unsupported.ts`). The service managers, `setup` and `permission` of node's `Platform` serve CLI verbs that stay node and are not here.

use std::sync::Arc;

use crate::json;
use crate::node;
use crate::notify::helper::HelperNotifier;
use crate::notify::log::Log;
use crate::notify::notifier::{Notice, Notifier, PostResult};
use crate::notify::options::Backend;

/// A chosen backend: its name, which the `started` line carries, and the notifier the engine posts through.
pub struct Platform {
    pub name: &'static str,
    pub notifier: Box<dyn Notifier>,
}

/// The name node's `process.platform` gives this system: `darwin` for macOS, `win32` for Windows, `std::env::consts::OS` for the rest.
pub fn os_name() -> &'static str {
    match std::env::consts::OS {
        "macos" => "darwin",
        "windows" => "win32",
        other => other,
    }
}

/// The helper app: `TA_NOTIFY_APP` when it is set and not empty, else the per-user Application Support copy (`appPath` of `paths.ts`).
pub fn app_path(ta_notify_app: Option<&str>, home: &str) -> String {
    match ta_notify_app {
        Some(app) if !app.is_empty() => app.to_owned(),
        _ => {
            let support = node::join(&node::join(home, "Library"), "Application Support");
            node::join(&node::join(&support, "tagents"), "TagentsNotify.app")
        }
    }
}

/// The backend a start uses for `backend` on the system `os` (node's name for it), or `None` for backend `none`: nothing posts. `app` is the helper app's path, `app_path`'s answer, used only by the macOS backend. A system with no backend gets the `unsupported` platform, which the service reads by its name.
pub fn pick(os: &str, backend: Backend, log: Arc<dyn Log>, app: &str) -> Option<Platform> {
    match backend {
        Backend::None => None,
        Backend::Log => Some(Platform {
            name: "log",
            notifier: Box::new(LogNotifier { log }),
        }),
        Backend::Auto | Backend::Macos if os == "darwin" => Some(Platform {
            name: "macos",
            notifier: Box::new(HelperNotifier::new(app)),
        }),
        Backend::Auto | Backend::Macos => Some(Platform {
            name: "unsupported",
            notifier: Box::new(Unsupported { os: os.to_owned() }),
        }),
    }
}

/// The backend that posts nothing and says so: for `backend: log`, and for seeing what the engine would have said before a real banner is involved.
pub struct LogNotifier {
    log: Arc<dyn Log>,
}

impl Notifier for LogNotifier {
    fn name(&self) -> &str {
        "log"
    }

    /// One line per notice, the text as JSON so that a multi-line body stays on it.
    fn post(&mut self, notice: &Notice) -> Result<PostResult, String> {
        let click = if notice.click.argv.is_empty() {
            "click=terminal".to_owned()
        } else {
            format!("click={}", notice.click.argv.join(" "))
        };
        let pid = match notice.terminal_pid {
            Some(pid) => format!("pid={pid}"),
            None => "pid=none".to_owned(),
        };
        let skip = if notice.skip_if_frontmost == Some(true) {
            "skip-if-frontmost"
        } else {
            "always"
        };
        self.log.line(&[
            "post",
            &notice.id,
            notice.kind.as_str(),
            &json::quote(&notice.title),
            &json::quote(&notice.subtitle),
            &json::quote(&notice.body),
            &click,
            &pid,
            skip,
        ]);
        Ok(PostResult {
            shown: true,
            why: None,
        })
    }

    fn withdraw(&mut self, id: &str) -> Result<(), String> {
        self.log.line(&["withdraw", id]);
        Ok(())
    }
}

/// The notifier of a machine whose backend is not written yet: it refuses to post and says why, instead of the engine silently dropping notices.
pub struct Unsupported {
    os: String,
}

impl Unsupported {
    fn refusal(&self) -> String {
        format!("no notification backend for {} yet", self.os)
    }
}

impl Notifier for Unsupported {
    fn name(&self) -> &str {
        "unsupported"
    }

    fn post(&mut self, _notice: &Notice) -> Result<PostResult, String> {
        Err(self.refusal())
    }

    fn withdraw(&mut self, _id: &str) -> Result<(), String> {
        Err(self.refusal())
    }
}

#[cfg(test)]
mod tests;
