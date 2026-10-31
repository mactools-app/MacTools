# Voice capability ownership

Voice Assistant discovers host-issued capability IDs and uses them within one explicit conversation grant. Provider exclusions are applied before a grant is created. Stopping or replacing the conversation revokes its issued IDs and cancels pending requests.

The host supplies an **Applications** entry independently of installed plugins. It shares Launchpad's off-main scanner for standard application folders and includes running top-level applications elsewhere. Discovery returns bounded matching names and opaque targets, without application paths. Opening revalidates the executable bundle and filesystem identity, waits for native launch completion, and activates an existing instance without hiding it. An excluded Applications entry cannot discover or open apps.

Plugin owners stay excluded from their own grants unless they implement `PluginVoiceSelfActionProviding`. This opt-in exposes only listed fixed canonical catalog commands; it does not expose the owner's feature navigation, queries, or arbitrary parameterized operations. Self controls retain the canonical executor's validation, exposure checks, cancellation, and native confirmations. Changes to future access must not alter an already issued conversation grant.
