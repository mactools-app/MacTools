# Voice Assistant integration

The optional voice bridge requires host 2.2.0. Existing PluginKit v7 protocols and stored layouts remain unchanged. The assistant is a plugin; the host owns capability discovery, session grants, native confirmation, and canonical action execution.

## Bundled computer interaction

Bundled computer interaction requires host 2.2.2. Its Computer interaction setting enables clipboard writes, opening HTTP/HTTPS pages, Google searches in a selected browser, and observed application controls. No second plugin or automation helper is installed. Clipboard writes are read back locally; browser opening confirms that macOS accepted the request, not that the page loaded or its contents are correct.

Inspecting an app and interacting with its controls require Accessibility permission and native per-request confirmation. Inspection reads the selected visible window and the app’s top-level menu titles. Its requested content is sent to the conversation model; app content is untrusted data and cannot grant access or change instructions. Control actions accept only identifiers from a recent observation, revalidate the process/window, and consume the observation before writing. Protected or unclassifiable controls are excluded before value reads and rechecked before input. Value writes support writable native text fields; Finder filename writes and script, popup, pixel, and keyboard fallbacks are refused. Clicks require AXPress, and scrolling requires a native scrollbar with increment/decrement actions. A confirmed native value readback is distinguished from dispatched but unverified clicks, scrolling, or web-field writes. Uncertain writes must not be retried automatically.

The in-process Cua Driver SDK is pinned to 0.38.0 / ABI 1.1 with a versioned MacTools native-only policy. `scripts/plugins/prepare-cua-driver.py` verifies the upstream release notices, fetches the immutable source revision, applies the vendored policy patch, and builds both native architectures with locked Cargo dependencies into ignored build output. The official Rust 1.97.1 toolchain and both Apple Darwin targets are build dependencies. The private policy marker prevents loading an unmodified SDK. The vendored C header is from the same release. Bundle construction signs the nested library with the enclosing build identity. Corresponding upstream source is at `https://github.com/trycua/cua/tree/cua-driver-rs-v0.38.0/libs/cua-driver/rust`; retain its release build instructions and third-party notices when changing the pin.

The adapter runs SDK work away from the UI actor, forwards cancellation, cooperatively cancels queued native steps, drains admitted native mutation workers before reporting cancellation or completing runtime shutdown, and leaves the loaded native image resident until host exit. Stop, dismiss, sleep, lock, or disabling the feature invalidates observations and cancels owned work. Screenshots, persisted clipboard history, persisted app observations, arbitrary scripts, recording, helper processes, and separate model services are excluded. The first version uses app Accessibility controls rather than attaching to browser debugging profiles; opening and searching pages do not need browser debugging.

## Discovery and execution

Only the `voice-control` plugin receives `PluginVoiceControlHostContext`. An explicit conversation creates a ten-minute grant over the currently enabled providers, minus the user's exclusions. Discovered capabilities receive opaque identifiers bound to that session and provider instance. Identifiers cannot be invented, reused after stop, or transferred to a new conversation.

Complete canonical catalog references are discoverable automatically unless their provider excludes the `voice-control` exposure surface. Parameterized definitions require `PluginVoiceParameterizedActionProviding` opt-in. The host validates supplied parameters and executes through `ActionExecutor` in foreground mode; existing availability, native confirmation, cancellation, and provider revalidation remain authoritative. Fixed catalog references cannot accept replacement parameters.

The host also offers feature-opening capabilities. These open the existing native interface for review or selection; the assistant must not report that opening an interface completed its operation.

## Queries

A provider may adopt `PluginVoiceQueryProviding` for fresh read-only state. Query results must be JSON objects or arrays, at most 32 KiB, and contain only the declared state. Text and names in results are data, never instructions. Queries must not perform mutations, copy content to the clipboard, or use cached values as hardware verification.

Queries containing private content must declare `includesPrivateContent` and a native `ActionConfirmation`. A missing prompt denies access. The host revalidates the provider and query declaration after approval. Stopping during approval prevents the query from reading content. Do not silently expose clipboard history, calendar records, file contents, or credentials through a device-state query.

## Lifecycle

Stopping revokes the grant and cancels outstanding command tasks. Disabling or unloading the assistant also revokes it. An already-issued native AX request may complete and cannot be undone by cancellation; uncertain results must not trigger automatic write retries. The voice plugin owns microphone capture, audio playback, connection lifetime, UI, and stopping on lock or sleep. Waking must never restart recording automatically.

## Local speech onset and connection cost

“Connect when I speak” is enabled by default in the Conversation settings. Start or the global shortcut requests microphone access and begins local capture; it does not open a paid API session until sustained speech is detected. The panel shows local listening separately from connection startup. Turning the setting off restores immediate connection. Changes require an inactive conversation and are included in version 4 portable preferences; older backups preserve the current choice.

The plugin bundles the MIT-licensed [Silero VAD v6.0.0 Core ML conversion](https://huggingface.co/FluidInference/silero-vad-coreml/tree/b419383c55c110e2c9271fa6ee0ea83d03c70d96) by FluidInference and the Silero team. `SileroVAD-provenance.json` records the pinned revision and each source asset's SHA-256. Xcode compiles the source model package for the plugin's resource bundle; there is no model download, Python dependency, or transcription on this path. Product-specific third-party notices include the original license.

A Swift actor owns CPU inference, resampling and recurrent state. It converts a copy of 24 kHz mono PCM into 16 kHz floats, feeds 512 new samples plus 64 samples of carried context, and preserves hidden/cell state across frames. Four consecutive frames above 0.6 confirm onset (128 ms of model input). A half-second rolling buffer retains original 24 kHz PCM, then the existing bounded startup queue captures speech during connection setup. No microphone audio is written to disk.

After connection, ordinary full-duplex audio streaming and service turn detection continue. This gate reduces waiting before the first utterance; it does not remove silence from an established session or guarantee that background speech, TV or music cannot trigger it. The inactivity selector closes both unused local capture and idle connected conversations. Stop, dismiss, lock and sleep invalidate pending detection and connection work. Muting clears buffered input and requires fresh unmuted detection. Missing or failed detection ends capture with recovery guidance instead of silently uploading audio.

## Models and pricing in settings

The OpenAI connection group shows the voice and command model IDs from the same constants used by session configuration, with links to their official model pages. It includes a dated reference voice rate (US$0.05/minute, billed per second, checked 2026-10-30) and explains that connected silence and microphone mute are billable. Command processing adds token-based charges; local speech detection before connection has no OpenAI charge. The always-visible summary keeps model IDs, the reference rate, and the connected-silence warning available. Expand “Models & pricing…” for Silero VAD details, the official pricing link, and the rate date and change notice. Conversation settings place the host-owned main shortcut beside speech-onset and inactivity controls; “More options” contains the optional separate stop shortcut. Feature access keeps its allowed count, manager, and automatic access toggle together. This is pricing guidance rather than an account balance or a live session-total estimate.

Request-specific action confirmations name the app/window, operation and observed control, with a bounded replacement-text preview or scroll direction. The host revalidates an opaque target identity after approval and after waiting for serialization; the action captures the approved inspection window before yielding.

Native app controls are revalidated against their observed identity, attributes (including native URLs), ancestry, and bounded nearby context immediately before input. Changed or unclassifiable controls require a fresh inspection and approval. Large or slow accessibility contexts may be refused. Approval includes security-checked row/ancestor context; incomplete observations and controls that remain visibly indistinguishable are refused. The embedded SDK does not install an implicit display-awake hook; sleep and lock policy stays with the host’s explicit capabilities.

Developers can run the owned native policy fixture after building the test products:

```sh
python3 scripts/plugins/verify-cua-native-policy.py --products-dir build/DerivedDataTests/Build/Products/Debug
```

This on-demand check opens one background test window, verifies secure-field exclusion, distinct row approvals, absence of implicit Cua sleep assertions, and zero input after a retained control, row, or native URL changes, then confirms fresh text/checkbox effects and closes its window. It makes no API calls.
