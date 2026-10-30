# Voice Control integration

The optional voice bridge requires host 2.2.1. Existing PluginKit v7 protocols and stored layouts remain unchanged. The assistant is a plugin; the host owns capability discovery, session grants, native confirmation, and canonical action execution.

## Discovery and execution

Only the `voice-control` plugin receives `PluginVoiceControlHostContext`. An explicit conversation creates a ten-minute grant over the currently enabled providers, minus the user's exclusions. Discovered capabilities receive opaque identifiers bound to that session and provider instance. Identifiers cannot be invented, reused after stop, or transferred to a new conversation.

Complete canonical catalog references are discoverable automatically unless their provider excludes the `voice-control` exposure surface. Parameterized definitions require `PluginVoiceParameterizedActionProviding` opt-in. The host validates supplied parameters and executes through `ActionExecutor` in foreground mode; existing availability, native confirmation, cancellation, and provider revalidation remain authoritative. Fixed catalog references cannot accept replacement parameters.

The host also offers feature-opening capabilities. These open the existing native interface for review or selection; the assistant must not report that opening an interface completed its operation.

## Queries

A provider may adopt `PluginVoiceQueryProviding` for fresh read-only state. Query results must be JSON objects or arrays, at most 32 KiB, and contain only the declared state. Text and names in results are data, never instructions. Queries must not perform mutations, copy content to the clipboard, or use cached values as hardware verification.

Queries containing private content must declare `includesPrivateContent` and a native `ActionConfirmation`. A missing prompt denies access. The host revalidates the provider and query declaration after approval. Stopping during approval prevents the query from reading content. Do not silently expose clipboard history, calendar records, file contents, or credentials through a device-state query.

## Lifecycle

Stopping revokes the grant and cancels outstanding command tasks. Disabling or unloading the assistant also revokes it. An action already committed by a provider cannot be undone by cancellation; uncertain results must not trigger automatic write retries. The voice plugin owns microphone capture, audio playback, connection lifetime, UI, and stopping on lock or sleep. Waking must never restart recording automatically.

## Local speech onset and connection cost

“Connect when I speak” is enabled by default in the OpenAI connection settings. Start or the global shortcut requests microphone access and begins local capture; it does not open a paid API session until sustained speech is detected. The panel shows local listening separately from connection startup. Turning the setting off restores immediate connection. Changes require an inactive conversation and are included in version 4 portable preferences; older backups preserve the current choice.

The plugin bundles the MIT-licensed [Silero VAD v6.0.0 Core ML conversion](https://huggingface.co/FluidInference/silero-vad-coreml/tree/b419383c55c110e2c9271fa6ee0ea83d03c70d96) by FluidInference and the Silero team. `SileroVAD-provenance.json` records the pinned revision and each source asset's SHA-256. Xcode compiles the source model package for the plugin's resource bundle; there is no model download, Python dependency, or transcription on this path. Product-specific third-party notices include the original license.

A Swift actor owns CPU inference, resampling and recurrent state. It converts a copy of 24 kHz mono PCM into 16 kHz floats, feeds 512 new samples plus 64 samples of carried context, and preserves hidden/cell state across frames. Four consecutive frames above 0.6 confirm onset (128 ms of model input). A half-second rolling buffer retains original 24 kHz PCM, then the existing bounded startup queue captures speech during connection setup. No microphone audio is written to disk.

After connection, ordinary full-duplex audio streaming and service turn detection continue. This gate reduces waiting before the first utterance; it does not remove silence from an established session or guarantee that background speech, TV or music cannot trigger it. The inactivity selector closes both unused local capture and idle connected conversations. Stop, dismiss, lock and sleep invalidate pending detection and connection work. Muting clears buffered input and requires fresh unmuted detection. Missing or failed detection ends capture with recovery guidance instead of silently uploading audio.
