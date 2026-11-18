# Tailscale

Install and start Tailscale on the Mac. In the MacTools feature panel, choose **Sign In to Tailscale** to open the device authorization page in your browser. Once signed in, use the switch to connect or disconnect. The panel refreshes after wake and network changes and checks periodically for changes made in the Tailscale client. Use **Refresh Status** to check immediately.

- Copy this Mac’s IP address or MagicDNS name from the panel. Open another device for its addresses and **Pin to Favorites**. Favorite device IDs stay on this Mac.
- Under **Exit Node**, open an online, approved device and choose **Use This Exit Node** to route internet traffic through it. The panel reads the selected node back from Tailscale. Use **Turn Off Exit Node** to stop using it.
- Open a device and choose **Test Connectivity** to run a Tailscale ping. The result shows whether the device replied directly, through a relay, or did not reply. The test measures reachability at the Tailscale layer.
