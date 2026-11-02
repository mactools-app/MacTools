# Voice capability ownership

Voice Assistant discovers host-issued capability IDs and uses them within one explicit conversation grant. Provider exclusions are applied before a grant is created. Stopping or replacing the conversation revokes its issued IDs and cancels pending requests.

The host supplies an **Applications** entry independently of installed plugins. It shares Launchpad's off-main scanner for standard application folders and includes running top-level applications elsewhere. Discovery returns bounded matching names and opaque targets, without application paths. Opening revalidates the executable bundle and filesystem identity, waits for native launch completion, and activates an existing instance without hiding it. An excluded Applications entry cannot discover or open apps.

Plugin owners stay excluded from their own grants unless they implement `PluginVoiceSelfActionProviding`. This opt-in exposes only listed fixed canonical catalog commands; it does not expose the owner's feature navigation, queries, or arbitrary parameterized operations. Self controls retain the canonical executor's validation, exposure checks, cancellation, and native confirmations. Changes to future access must not alter an already issued conversation grant.

Host 2.2.2 adds `PluginVoiceSelfParameterizedActionProviding` for bundled computer interaction. Only IDs listed in both its self-action set and `PluginVoiceParameterizedActionProviding` are discoverable. The host rechecks both declarations after approval and before admission. Existing fixed-self declarations do not grant parameterized access; owner queries and feature navigation remain excluded.

The bundled Voice Assistant app-inspection action uses explicit, device-local setup consent and is available only during active conversations. Its canonical read action needs no per-request dialog after that consent; input actions retain concrete native approvals. The setup consent cannot be granted by voice or imported through portable preferences. Stop, dismissal or consent revocation invalidates queued work and retained targets.
