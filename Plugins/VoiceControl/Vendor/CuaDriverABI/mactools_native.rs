//! MacTools' bounded, in-process AX policy over Cua's retained exact-window targets.
use super::ToolState;
use crate::ax::bindings::*;
use crate::ax::snapshot::RetainedElement;
use core_foundation::{array::CFArray, base::{CFGetTypeID, CFRelease, CFTypeRef, TCFType}, boolean::CFBoolean, string::CFString};
use cua_driver_core::{element_token::ResolvedElement, protocol::ToolResult};
use serde_json::Value;
use std::{cell::Cell, sync::{Arc, atomic::{AtomicU64, Ordering}}};

#[derive(Clone, Copy)]
struct ObservationPolicy { window: u32, toolbar: bool, incomplete: bool }
thread_local! { static OBSERVATION: Cell<Option<ObservationPolicy>> = const { Cell::new(None) }; }

/// The policy stays on the blocking AX thread through tree and semantic capture.
pub fn observe<T>(window: u32, toolbar: bool, work: impl FnOnce() -> T) -> T {
    struct Restore(Option<ObservationPolicy>);
    impl Drop for Restore { fn drop(&mut self) { OBSERVATION.set(self.0); } }
    let _restore = Restore(OBSERVATION.replace(Some(ObservationPolicy { window, toolbar, incomplete: false })));
    work()
}
pub fn observation_incomplete() -> bool { OBSERVATION.get().is_some_and(|p| p.incomplete) }
pub fn mark_observation_incomplete() {
    if let Some(mut policy) = OBSERVATION.get() { policy.incomplete = true; OBSERVATION.set(Some(policy)); }
}
/// Optional metadata may be absent, but IPC failures cannot prove completeness.
pub fn observation_attribute_read(status: AXError, has_value: bool) {
    if status != kAXErrorAttributeUnsupported && status != kAXErrorNoValue
        && (status != kAXErrorSuccess || !has_value) { mark_observation_incomplete(); }
}
/// An action-list failure is not a successfully observed empty action list.
pub fn observation_action_read(status: AXError, has_value: bool) {
    if status != kAXErrorSuccess || !has_value { mark_observation_incomplete(); }
}
pub fn toolbar_observation() -> bool { OBSERVATION.get().is_some_and(|p| p.toolbar) }
pub fn observation_scope() -> Option<(u32, bool)> { OBSERVATION.get().map(|p| (p.window, p.toolbar)) }
pub fn classified_role(role: Option<&str>) -> bool {
    role.is_some_and(|role| !role.trim().is_empty() && role != "AXUnknown")
}
pub fn skips_observation_role(role: &str) -> bool {
    let role: String = role.chars().filter(|c| c.is_ascii_alphanumeric()).flat_map(char::to_lowercase).collect();
    toolbar_observation() && (role.contains("webarea") || role.contains("documentweb") || role == "document")
}

/// Application-root sheets and menu bars are outside the approved window.
pub unsafe fn observation_root(element: AXUIElementRef) -> bool {
    if OBSERVATION.get().is_none() { return true; }
    match copy_string_attr(element, "AXRole").as_deref() {
        Some("AXWindow") => true,
        Some(_) => false,
        None => { mark_observation_incomplete(); false }
    }
}

/// Prove window ownership before values or contextual content are read.
pub unsafe fn observation_allows(element: AXUIElementRef) -> bool {
    let Some(policy) = OBSERVATION.get() else { return true; };
    if crate::ax::exact_target::element_window_id(element) == Some(policy.window) { return true; }
    mark_observation_incomplete();
    false
}

/// Unlike the general SDK helper, failed child IPC is not an empty subtree.
pub unsafe fn observation_children(element: AXUIElementRef) -> Vec<AXUIElementRef> {
    if OBSERVATION.get().is_none() { return copy_children(element); }
    let raw = match optional_attribute(element, "AXChildren") {
        Ok(raw) if raw.is_null() => return Vec::new(),
        Ok(raw) => raw,
        Err(()) => { mark_observation_incomplete(); return Vec::new(); }
    };
    if CFGetTypeID(raw) != CFArray::<CFTypeRef>::type_id() {
        CFRelease(raw); mark_observation_incomplete(); return Vec::new();
    }
    let children = CFArray::<CFTypeRef>::wrap_under_create_rule(raw as _);
    children.iter().filter_map(|child| {
        let child = *child;
        if CFGetTypeID(child) != AXUIElementGetTypeID() { mark_observation_incomplete(); return None; }
        core_foundation::base::CFRetain(child);
        Some(child as AXUIElementRef)
    }).collect()
}

static EPOCH: AtomicU64 = AtomicU64::new(1);
tokio::task_local! { static ADMISSION: u64; }
pub fn current_epoch() -> u64 { EPOCH.load(Ordering::Acquire) }
pub fn cancel_pending() { EPOCH.fetch_add(1, Ordering::AcqRel); }
pub fn reset() { EPOCH.fetch_add(1, Ordering::AcqRel); }
fn is_current(epoch: u64) -> bool { current_epoch() == epoch }
pub async fn scope<F: std::future::Future>(epoch: u64, future: F) -> F::Output {
    ADMISSION.scope(epoch, future).await
}

/// Unsupported/empty metadata is distinct from an IPC or type failure.
pub(crate) unsafe fn optional_attribute(element: AXUIElementRef, name: &str) -> Result<CFTypeRef, ()> {
    let name = CFString::new(name);
    let mut value = std::ptr::null();
    let status = AXUIElementCopyAttributeValue(element, name.as_concrete_TypeRef(), &mut value);
    observation_attribute_read(status, !value.is_null());
    if status == kAXErrorAttributeUnsupported || status == kAXErrorNoValue { return Ok(std::ptr::null()); }
    if status != kAXErrorSuccess || value.is_null() { return Err(()); }
    Ok(value)
}

/// Refuse protected controls and failed security reads before reading their values.
pub unsafe fn control_allowed(element: AXUIElementRef) -> bool { control_security(element).unwrap_or(false) }
pub unsafe fn control_security(element: AXUIElementRef) -> Result<bool, ()> {
    if element.is_null() { return Err(()); }
    let role = copy_string_attr(element, "AXRole");
    if !classified_role(role.as_deref()) { return Err(()); }
    if role.as_deref() == Some("AXSecureTextField") { return Ok(false); }
    let subrole = optional_attribute(element, "AXSubrole")?;
    if !subrole.is_null() {
        if core_foundation::base::CFGetTypeID(subrole) != CFString::type_id() {
            CFRelease(subrole); return Err(());
        }
        if CFString::wrap_under_create_rule(subrole as _).to_string() == "AXSecureTextField" { return Ok(false); }
    }
    // AppKit's isAccessibilityProtectedContent maps to AXContainsProtectedContent.
    // Also honor the older embedding-specific spelling used by custom AX providers.
    for name in ["AXContainsProtectedContent", "AXProtectedContent"] {
        let protected = optional_attribute(element, name)?;
        if protected.is_null() { continue; }
        if core_foundation::base::CFGetTypeID(protected) != CFBoolean::type_id() {
            CFRelease(protected); return Err(());
        }
        let is_protected: bool = CFBoolean::wrap_under_create_rule(protected as _).into();
        if is_protected { return Ok(false); }
    }
    Ok(true)
}

fn text_role(role: &str) -> bool { matches!(role, "AXTextField" | "AXTextArea") }
fn scroll_action(direction: &str) -> Option<(&'static str, &'static str)> {
    match direction {
        "up" => Some(("AXVerticalScrollBar", "AXDecrement")),
        "down" => Some(("AXVerticalScrollBar", "AXIncrement")),
        "left" => Some(("AXHorizontalScrollBar", "AXDecrement")),
        "right" => Some(("AXHorizontalScrollBar", "AXIncrement")),
        _ => None,
    }
}

unsafe fn scrollbar(mut current: RetainedElement, attribute: &str, epoch: u64) -> Result<RetainedElement, &'static str> {
    for _ in 0..12 {
        if !is_current(epoch) { return Err("Cancelled before scrolling."); }
        let ptr = current.as_ptr() as AXUIElementRef;
        AXUIElementSetMessagingTimeout(ptr, 0.25);
        if let Some(bar) = copy_element_attr(ptr, attribute) {
            let result = RetainedElement::retain(bar as usize); CFRelease(bar as CFTypeRef); return Ok(result);
        }
        if copy_string_attr(ptr, "AXRole").as_deref() == Some("AXWindow") { break; }
        let parent = copy_element_attr(ptr, "AXParent").ok_or("No native scrollbar is available.")?;
        current = RetainedElement::retain(parent as usize); CFRelease(parent as CFTypeRef);
    }
    Err("No native scrollbar is available; no input was sent.")
}

pub async fn invoke(state: &Arc<ToolState>, tool: &str, args: &Value) -> ToolResult {
    let Some(epoch) = ADMISSION.try_with(|epoch| *epoch).ok().filter(|epoch| is_current(*epoch)) else {
        return ToolResult::error("Cancelled or missing native admission scope.");
    };
    let pid = match super::target_pid(state, args) { Ok(p) => p, Err(e) => return e };
    let (window, mut element) = match state.snapshots.resolve(pid, args) {
        Ok(ResolvedElement::Element { window_id, element, .. }) => (window_id, element),
        _ => return ToolResult::error("A fresh observed native control is required."),
    };
    let Some(semantics) = element.semantics().cloned() else { return stale_control(); };
    let window = match u32::try_from(window) { Ok(w) => w, Err(_) => return ToolResult::error("Invalid window.") };
    if args.get("window_id").and_then(Value::as_u64).is_some_and(|w| w != window as u64) {
        return ToolResult::error("The observed window does not match the request.");
    }
    let direction = args.get("direction").and_then(Value::as_str).unwrap_or("");
    let scroll = if tool == "scroll" {
        let Some(pair) = scroll_action(direction) else { return ToolResult::error("Invalid direction."); };
        let guard = element.clone();
        element = match tokio::task::spawn_blocking(move || unsafe { scrollbar(guard, pair.0, epoch) }).await {
            Ok(Ok(bar)) => bar,
            _ => return ToolResult::error("No bounded native scrollbar is available; no input was sent."),
        };
        Some(pair.1)
    } else { None };
    let _lease = match super::gate_background_window_action(pid, window,
        Some(element.as_ptr()), cua_driver_core::background_input::BackgroundAction::AxSemantic).await {
        Ok(lease) => lease, Err(refusal) => return refusal,
    };
    if !is_current(epoch) { return ToolResult::error("Cancelled before native dispatch."); }
    let tool = tool.to_owned();
    let value = args.get("value").and_then(Value::as_str).unwrap_or("").to_owned();
    let result = tokio::task::spawn_blocking(move || unsafe {
        let ptr = element.as_ptr() as AXUIElementRef;
        AXUIElementSetMessagingTimeout(ptr, 0.5);
        if !control_allowed(ptr) { return ToolResult::error("Protected or unavailable native control."); }
        if !semantics.matches_current() { return stale_control(); }
        if tool == "set_value" {
            let role = copy_string_attr(ptr, "AXRole").unwrap_or_default();
            // Finder's displayed names may echo AXValue without renaming the file.
            let finder_name = crate::apps::bundle_id_for_pid(pid).as_deref() == Some("com.apple.finder")
                && copy_string_attr(ptr, "AXSubrole").as_deref() != Some("AXSearchField");
            if !text_role(&role) || finder_name || !is_attribute_settable(ptr, "AXValue") {
                return ToolResult::error("Only writable native text fields are supported; no fallback was used.");
            }
            let native_readback = semantics.trusts_native_readback();
            if !semantics.matches_current() { return stale_control(); }
            if !is_current(epoch) || !control_allowed(ptr) { return ToolResult::error("Cancelled or protected before writing."); }
            let status = set_string_attr(ptr, "AXValue", &value);
            if status != kAXErrorSuccess { return ToolResult::error("Native text write failed; do not automatically retry."); }
            let confirmed = native_readback && is_current(epoch) && copy_string_attr(ptr, "AXValue").as_deref() == Some(value.as_str());
            return ToolResult::text("Native text input dispatched.").with_structured(serde_json::json!({
                "effect": if confirmed { "confirmed" } else { "unverifiable" }
            }));
        }
        let action = scroll.unwrap_or("AXPress");
        if !copy_action_names(ptr).iter().any(|candidate| candidate == action) {
            return ToolResult::error("This control has no supported native action; no fallback was used.");
        }
        let count = if scroll.is_some() { 3 } else { 1 };
        for _ in 0..count {
            if !is_current(epoch) || !control_allowed(ptr) { return ToolResult::error("Cancelled before the next native step."); }
            if perform_action(ptr, action) != kAXErrorSuccess {
                return ToolResult::error("Native action failed or is uncertain; do not automatically retry.");
            }
        }
        ToolResult::text("Native input dispatched; inspect the fresh observation.")
            .with_structured(serde_json::json!({ "effect": "unverifiable" }))
    }).await;
    result.unwrap_or_else(|_| ToolResult::error("Native worker failed; its effect is uncertain."))
}

/// Add only already-authorized, security-checked human context; no extra app read occurs here.
pub fn annotate_observation(state: &Arc<ToolState>, pid: i32, rows: &mut [Value]) {
    for row in rows {
        let Some(token) = row.get("element_token").and_then(Value::as_str) else { continue; };
        let args = serde_json::json!({"element_token": token});
        let Ok(ResolvedElement::Element { element, .. }) = state.snapshots.resolve(pid, &args) else { continue; };
        row["native_input_ready"] = Value::Bool(element.semantics().is_some());
        let Some(context) = element.semantics().and_then(|stamp| stamp.approval_context()) else { continue; };
        row["context"] = Value::String(context);
    }
}

fn stale_control() -> ToolResult {
    ToolResult::error("The observed control or its context changed. Inspect and approve it again; no input was sent.")
        .with_structured(serde_json::json!({"mactools_refusal":"stale_control"}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn failed_native_reads_make_the_observation_incomplete() {
        for (status, has_value, incomplete) in [(kAXErrorSuccess, true, false),
            (kAXErrorSuccess, false, true), (-25204, false, true),
            (kAXErrorAttributeUnsupported, false, false), (kAXErrorNoValue, false, false)] {
            observe(1, false, || {
                observation_attribute_read(status, has_value);
                assert_eq!(observation_incomplete(), incomplete);
            });
        }
        for (status, has_value, incomplete) in [(kAXErrorSuccess, true, false),
            (kAXErrorSuccess, false, true), (-25204, false, true),
            (kAXErrorActionUnsupported, false, true)] {
            observe(1, false, || {
                observation_action_read(status, has_value);
                assert_eq!(observation_incomplete(), incomplete);
            });
        }
    }
    #[test] fn failed_child_read_cannot_prove_an_empty_complete_scope() {
        observe(1, false, || unsafe {
            let missing = AXUIElementCreateApplication(i32::MAX);
            assert!(!observation_incomplete());
            assert!(observation_children(missing).is_empty());
            assert!(observation_incomplete());
            CFRelease(missing as _);
        });
    }
    #[test] fn cancellation_survives_runtime_restart() {
        let old = current_epoch(); cancel_pending(); reset();
        assert!(!is_current(old)); assert!(is_current(current_epoch()));
    }
    #[test] fn native_routes_are_bounded() {
        assert!(text_role("AXTextField")); assert!(text_role("AXTextArea"));
        assert!(!text_role("AXPopUpButton")); assert!(!text_role("AXSecureTextField"));
        assert_eq!(scroll_action("down"), Some(("AXVerticalScrollBar", "AXIncrement")));
        assert_eq!(scroll_action("diagonal"), None);
    }
}
