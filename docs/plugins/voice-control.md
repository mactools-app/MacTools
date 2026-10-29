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
