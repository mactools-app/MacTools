# Bitwarden vault

Install the official Bitwarden CLI with `brew install bitwarden-cli`. Build the plugin with `make build-plugin PLUGIN=bitwarden` and start MacTools Dev with `make run`. Open the vault from the Bitwarden panel row or settings page.

Leave the server field blank to use Bitwarden's US cloud. Enter the HTTPS vault URL for Bitwarden EU or a self-hosted server. Two-step sign-in supports an authenticator code, an email code, and YubiKey OTP.

The plugin uses a dedicated CLI data directory, so its account and lock state are independent of the Bitwarden desktop app and the terminal's CLI session. Closing the workspace, sleeping the Mac, or leaving the vault idle for five minutes locks the session. Copied values are cleared after 30 seconds if the clipboard still contains that copy.

For a local smoke test, use a test account and create a disposable login. Verify that searching by name, username, and website finds it, then edit it, move it to Trash, restore it, and lock and reopen the workspace. Organization items are read-only. Items that require a master-password reprompt are unavailable in the workspace.
