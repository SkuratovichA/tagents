//! Cases of `packages/notify/test/kinds.test.ts`, one Rust test each:
//! - AskUserQuestion is a question that arms the cache deadline: `ask_user_question_is_a_question_that_arms`
//! - ExitPlanMode is a question that carries the plan subtitle flag: `exit_plan_mode_carries_the_plan_flag`
//! - any other tool before it runs is nothing: `any_other_tool_before_it_runs_is_nothing`
//! - PostToolUse of the two question tools is the answer: `post_tool_use_of_a_question_tool_withdraws_and_cancels`
//! - Notification: the subtype decides, and a text with an unknown subtype is a permission: `notification_subtype_decides`
//! - Notification: idle_prompt, "waiting for your input", auth_success and a text-less one are ignored: `notifications_that_are_ignored`
//! - Stop of the main agent is turn_done; Stop with an agent id is ignored: `stop_of_the_main_agent_is_turn_done`
//! - SubagentStop is nothing: `subagent_stop_is_nothing`
//! - a question or a permission prompt with an agent id is still the agent's: `a_subagents_question_is_the_agents`
//! - SessionEnd is session_end and also withdraws and cancels: `session_end_withdraws_and_cancels`
//! - UserPromptSubmit withdraws and cancels without a notice of its own: `user_prompt_submit_withdraws_and_cancels`
//! - SessionStart withdraws and cancels without a notice of its own: `session_start_withdraws_and_cancels`
//! - QUESTION_TOOLS is the list both ends of a question go by: `question_tools_are_the_list_both_ends_go_by`
//! - a session without a pane of its own never counts: `a_session_without_a_pane_never_counts`

use super::*;

fn event(event: AgentHookEvent) -> AgentEvent {
    AgentEvent {
        at: 1_700_000_000_000.0,
        event,
        key: "12".into(),
        session_id: "sess-1".into(),
        agent_id: String::new(),
        pane: "%12".into(),
        cwd: "/work/proj".into(),
        transcript: String::new(),
        config_dir: String::new(),
        tool: String::new(),
        sub: String::new(),
        text: String::new(),
        label: String::new(),
    }
}

fn tool(event_name: AgentHookEvent, tool: &str) -> AgentEvent {
    AgentEvent {
        tool: tool.into(),
        ..event(event_name)
    }
}

fn notification(sub: &str, text: &str) -> AgentEvent {
    AgentEvent {
        sub: sub.into(),
        text: text.into(),
        ..event(AgentHookEvent::Notification)
    }
}

fn verdict(
    kind: Option<NoticeKind>,
    plan: bool,
    arms: bool,
    withdraw: bool,
    cancel: bool,
) -> Option<Verdict> {
    Some(Verdict {
        kind,
        plan,
        arms,
        withdraw,
        cancel,
    })
}

fn kind_of(e: &AgentEvent) -> Option<NoticeKind> {
    classify(e).and_then(|v| v.kind)
}

#[test]
fn ask_user_question_is_a_question_that_arms() {
    let e = tool(AgentHookEvent::PreToolUse, "AskUserQuestion");
    assert_eq!(
        classify(&e),
        verdict(Some(NoticeKind::Question), false, true, false, false)
    );
}

#[test]
fn exit_plan_mode_carries_the_plan_flag() {
    let v = classify(&tool(AgentHookEvent::PreToolUse, "ExitPlanMode")).unwrap();
    assert_eq!(v.kind, Some(NoticeKind::Question));
    assert!(v.plan);
}

#[test]
fn any_other_tool_before_it_runs_is_nothing() {
    assert_eq!(classify(&tool(AgentHookEvent::PreToolUse, "Bash")), None);
}

#[test]
fn post_tool_use_of_a_question_tool_withdraws_and_cancels() {
    for name in QUESTION_TOOLS {
        let v = classify(&tool(AgentHookEvent::PostToolUse, name));
        assert_eq!(v, verdict(None, false, false, true, true), "{name}");
    }
    assert_eq!(classify(&tool(AgentHookEvent::PostToolUse, "Bash")), None);
}

#[test]
fn notification_subtype_decides() {
    assert_eq!(
        kind_of(&notification("elicitation_dialog", "Pick")),
        Some(NoticeKind::Question)
    );
    let permission = classify(&notification("permission_prompt", "Allow Bash?")).unwrap();
    assert_eq!(permission.kind, Some(NoticeKind::Permission));
    assert!(permission.arms);
    assert_eq!(
        kind_of(&notification("something_new", "Needs you")),
        Some(NoticeKind::Permission)
    );
    assert_eq!(
        kind_of(&notification("", "Claude needs your permission")),
        Some(NoticeKind::Permission)
    );
}

#[test]
fn notifications_that_are_ignored() {
    assert_eq!(classify(&notification("idle_prompt", "anything")), None);
    assert_eq!(
        classify(&notification("", "Claude is Waiting For Your Input")),
        None
    );
    assert_eq!(
        classify(&notification("something_new", "waiting for your input")),
        None
    );
    assert_eq!(classify(&notification("auth_success", "Signed in")), None);
    assert_eq!(classify(&notification("something_new", "")), None);
}

#[test]
fn a_text_of_white_space_only_is_text_less() {
    // U+FEFF is white space to JavaScript's `trim` and not to `str::trim`.
    let bom = char::from_u32(0xfeff).unwrap().to_string();
    assert_eq!(
        classify(&notification("something_new", &format!("{bom} \n{bom}"))),
        None
    );
    assert_eq!(
        classify(&notification("something_new", &format!("{bom}x"))).and_then(|v| v.kind),
        Some(NoticeKind::Permission)
    );
}

#[test]
fn a_waiting_text_folds_ascii_case_only() {
    // U+0131 is not "i" to a regular expression without the `u` flag: a text spelled with them is a prompt.
    let dotless = format!("Wa{}ting for your input", char::from_u32(0x131).unwrap());
    assert_eq!(
        kind_of(&notification("", &dotless)),
        Some(NoticeKind::Permission)
    );
}

#[test]
fn stop_of_the_main_agent_is_turn_done() {
    assert_eq!(
        classify(&event(AgentHookEvent::Stop)),
        verdict(Some(NoticeKind::TurnDone), false, true, false, false)
    );
    let sub = AgentEvent {
        agent_id: "agent-7".into(),
        ..event(AgentHookEvent::Stop)
    };
    assert_eq!(classify(&sub), None);
}

#[test]
fn subagent_stop_is_nothing() {
    let named = AgentEvent {
        agent_id: "agent-7".into(),
        sub: "Explore".into(),
        ..event(AgentHookEvent::SubagentStop)
    };
    assert_eq!(classify(&named), None);
    assert_eq!(classify(&event(AgentHookEvent::SubagentStop)), None);
}

#[test]
fn a_subagents_question_is_the_agents() {
    let question = AgentEvent {
        agent_id: "agent-7".into(),
        ..tool(AgentHookEvent::PreToolUse, "AskUserQuestion")
    };
    assert_eq!(kind_of(&question), Some(NoticeKind::Question));
    let permission = AgentEvent {
        agent_id: "agent-7".into(),
        ..notification("permission_prompt", "m")
    };
    assert_eq!(kind_of(&permission), Some(NoticeKind::Permission));
}

#[test]
fn session_end_withdraws_and_cancels() {
    let e = AgentEvent {
        sub: "logout".into(),
        ..event(AgentHookEvent::SessionEnd)
    };
    assert_eq!(
        classify(&e),
        verdict(Some(NoticeKind::SessionEnd), false, false, true, true)
    );
}

#[test]
fn user_prompt_submit_withdraws_and_cancels() {
    assert_eq!(
        classify(&event(AgentHookEvent::UserPromptSubmit)),
        verdict(None, false, false, true, true)
    );
}

#[test]
fn session_start_withdraws_and_cancels() {
    assert_eq!(
        classify(&event(AgentHookEvent::SessionStart)),
        verdict(None, false, false, true, true)
    );
}

#[test]
fn question_tools_are_the_list_both_ends_go_by() {
    assert_eq!(QUESTION_TOOLS, ["AskUserQuestion", "ExitPlanMode"]);
    for name in QUESTION_TOOLS {
        assert_eq!(
            kind_of(&tool(AgentHookEvent::PreToolUse, name)),
            Some(NoticeKind::Question),
            "{name}"
        );
        assert!(
            classify(&tool(AgentHookEvent::PostToolUse, name))
                .unwrap()
                .cancel,
            "{name}"
        );
    }
}

#[test]
fn a_session_without_a_pane_never_counts() {
    let headless = |e: AgentEvent| AgentEvent {
        key: "s-abc".into(),
        pane: String::new(),
        ..e
    };
    assert_eq!(classify(&headless(event(AgentHookEvent::Stop))), None);
    assert_eq!(
        classify(&headless(notification("permission_prompt", "m"))),
        None
    );
    assert_eq!(
        classify(&headless(event(AgentHookEvent::UserPromptSubmit))),
        None
    );
    assert!(!counts_session("s-abc"));
    assert!(counts_session("12"));
}
