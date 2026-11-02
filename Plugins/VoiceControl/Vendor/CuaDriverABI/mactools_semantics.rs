//! Retained native identities and bounded semantic context, private to MacTools.
use crate::ax::{bindings::*, snapshot::RetainedElement, tree::AXNode};
use core_foundation::{array::CFArray, base::{CFEqual, CFGetTypeID, CFRelease, CFTypeRef, TCFType},
    boolean::CFBoolean, number::CFNumber, string::CFString, url::CFURL};
use std::{sync::Arc, time::{Duration, Instant}};

const ATTRIBUTES: &[&str] = &["AXRole", "AXSubrole", "AXIdentifier", "AXDOMIdentifier",
    "AXTitle", "AXDescription", "AXHelp", "AXValue", "AXPlaceholderValue", "AXIndex", "AXEnabled", "AXURL", "AXValueDescription"];
struct Anchor { element: RetainedElement, attributes: Vec<Option<String>>, actions: Vec<String> }
pub struct ControlStamp { chain: Vec<Anchor>, context: Vec<Anchor> }

unsafe fn attribute(ptr: AXUIElementRef, name: &str, deadline: Instant) -> Option<Option<String>> {
    if Instant::now() >= deadline { return None; }
    let raw = super::mactools_native::optional_attribute(ptr, name).ok()?;
    if raw.is_null() { return Some(None); }
    let kind = CFGetTypeID(raw);
    let text = if kind == CFString::type_id() {
        Some(CFString::wrap_under_get_rule(raw as _).to_string())
    } else if kind == CFURL::type_id() {
        Some(CFURL::wrap_under_get_rule(raw as _).absolute().get_string().to_string())
    } else if kind == CFBoolean::type_id() {
        Some(if bool::from(CFBoolean::wrap_under_get_rule(raw as _)) { "1" } else { "0" }.into())
    } else if kind == CFNumber::type_id() {
        CFNumber::wrap_under_get_rule(raw as _).to_f64().filter(|f| f.is_finite()).map(|f| {
            if f == f.trunc() && f.abs() < 1e15 { format!("{}", f as i64) } else { format!("{f}") }
        })
    } else { None };
    CFRelease(raw);
    let text = text?;
    if text.len() > 4096 { return None; }
    Some(Some(text))
}

unsafe fn anchor(element: RetainedElement, deadline: Instant) -> Option<Anchor> {
    if Instant::now() >= deadline { return None; }
    let ptr = element.as_ptr() as AXUIElementRef;
    if ptr.is_null() || CFGetTypeID(ptr as _) != AXUIElementGetTypeID() { return None; }
    AXUIElementSetMessagingTimeout(ptr, 0.025);
    if !super::mactools_native::control_security(ptr).ok()? { return None; }
    let attributes = ATTRIBUTES.iter().map(|name| attribute(ptr, name, deadline)).collect::<Option<Vec<_>>>()?;
    if attributes[0].as_deref().unwrap_or("").is_empty() || Instant::now() >= deadline { return None; }
    let mut actions = copy_action_names(ptr); actions.sort();
    Some(Anchor { element, attributes, actions })
}

unsafe fn children(ptr: AXUIElementRef, deadline: Instant) -> Option<Vec<RetainedElement>> {
    if Instant::now() >= deadline { return None; }
    let raw = super::mactools_native::optional_attribute(ptr, "AXChildren").ok()?;
    if raw.is_null() { return Some(Vec::new()); }
    if CFGetTypeID(raw) != CFArray::<CFTypeRef>::type_id() { CFRelease(raw); return None; }
    let array = CFArray::<CFTypeRef>::wrap_under_create_rule(raw as _);
    if array.len() > 24 { return None; }
    (0..array.len()).map(|i| {
        let value = *array.get(i)?;
        if CFGetTypeID(value) != AXUIElementGetTypeID() { return None; }
        Some(RetainedElement::retain(value as usize))
    }).collect()
}

unsafe fn context(element: &RetainedElement, depth: usize, output: &mut Vec<Anchor>, deadline: Instant) -> Option<()> {
    for child in children(element.as_ptr() as _, deadline)? {
        if output.len() >= 24 || Instant::now() >= deadline { return None; }
        let ptr = child.as_ptr() as AXUIElementRef;
        AXUIElementSetMessagingTimeout(ptr, 0.025);
        // Protected sibling contents never enter the semantic snapshot.
        if !super::mactools_native::control_security(ptr).ok()? { continue; }
        let node = anchor(child, deadline)?;
        let role = node.attributes[0].as_deref().unwrap_or("");
        if matches!(role, "AXGroup" | "AXRow" | "AXCell") {
            if depth == 0 { return None; }
            context(&node.element, depth - 1, output, deadline)?;
        }
        output.push(node);
    }
    Some(())
}

impl ControlStamp {
    unsafe fn capture(ptr: usize, deadline: Instant) -> Option<Self> {
        if Instant::now() >= deadline { return None; }
        let mut chain = Vec::new();
        let mut current = RetainedElement::retain(ptr);
        for _ in 0..12 {
            let node = anchor(current, deadline)?;
            let window = node.attributes[0].as_deref() == Some("AXWindow");
            let parent = if window { None } else {
                if Instant::now() >= deadline { return None; }
                let parent = copy_element_attr(node.element.as_ptr() as _, "AXParent")?;
                let retained = RetainedElement::retain(parent as usize); CFRelease(parent as _); Some(retained)
            };
            chain.push(node);
            if window {
                let mut nearby = Vec::new();
                // A cell's unchanged button is not the identity of its recycled row.
                // Prefer the row context, including peer cells, over an inner layout group.
                let container = chain.iter().skip(1).find(|n| n.attributes[0].as_deref() == Some("AXRow"))
                    .or_else(|| chain.iter().skip(1).find(|n| matches!(n.attributes[0].as_deref(),
                        Some("AXGroup" | "AXCell" | "AXToolbar"))));
                if let Some(container) = container {
                    context(&container.element, 2, &mut nearby, deadline)?;
                }
                return Some(Self { chain, context: nearby });
            }
            current = parent?;
        }
        None
    }

    /// Human-readable context comes only from the same security-checked retained snapshot.
    pub fn approval_context(&self) -> Option<String> {
        let primary = self.chain.first()?;
        let mut parts = Vec::<String>::new();
        for node in self.context.iter().chain(self.chain.iter().skip(1)) {
            if unsafe { CFEqual(node.element.as_ptr() as _, primary.element.as_ptr() as _) != 0 } { continue; }
            let role = node.attributes[0].as_deref().unwrap_or("");
            let fields: &[usize] = match role {
                "AXStaticText" | "AXHeading" | "AXTextField" | "AXTextArea" => &[7, 4, 5],
                "AXRow" | "AXCell" | "AXGroup" | "AXToolbar" => &[4, 5],
                _ => &[],
            };
            let text = fields.iter().filter_map(|index| node.attributes[*index].as_deref())
                .map(str::trim).find(|text| !text.is_empty());
            if let Some(text) = text.map(str::trim).filter(|text| !text.is_empty()) {
                if !parts.iter().any(|part| part == text) { parts.push(text.to_owned()); }
                if parts.len() == 3 { break; }
            }
        }
        if parts.is_empty() { return None; }
        let text = parts.join(" · ");
        Some(if text.chars().count() > 160 { text.chars().take(160).collect::<String>() + "…" } else { text })
    }

    /// Verify that the retained native object and its context still describe the observation.
    pub unsafe fn matches_current(&self) -> bool {
        let Some(first) = self.chain.first() else { return false; };
        let Some(current) = Self::capture(first.element.as_ptr(), Instant::now() + Duration::from_millis(250)) else { return false; };
        fn equal(old: &[Anchor], new: &[Anchor]) -> bool {
            old.len() == new.len() && old.iter().zip(new).all(|(a,b)| unsafe {
                CFEqual(a.element.as_ptr() as _, b.element.as_ptr() as _) != 0
                    && a.attributes == b.attributes && a.actions == b.actions
            })
        }
        equal(&self.chain, &current.chain) && equal(&self.context, &current.context)
    }
}

pub unsafe fn capture_observed(node: &AXNode, deadline: Instant) -> Option<Arc<ControlStamp>> {
    let stamp = ControlStamp::capture(node.element_ptr, deadline)?;
    let attributes = &stamp.chain.first()?.attributes;
    fn visible(value: Option<&str>) -> Option<&str> { value.map(str::trim).filter(|s| !s.is_empty()) }
    // Reject an object that changed between the AX tree read and snapshot preparation.
    if attributes[0].as_deref() != Some(node.role.as_str())
        || visible(attributes[4].as_deref()) != visible(node.title.as_deref())
        || visible(attributes[5].as_deref()) != visible(node.description.as_deref())
        || attributes[2] != node.identifier
        || visible(attributes[7].as_deref()).or_else(|| visible(attributes[8].as_deref()))
            != visible(node.value_state.as_deref()).or_else(|| visible(node.value.as_deref())) {
        return None;
    }
    Some(Arc::new(stamp))
}
