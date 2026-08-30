# RG Sibilance Lab standalone macOS shell

This directory is the source for the standalone WKWebView-based RG Sibilance Lab application.

The macOS build workflow embeds `webapp/app.html` into the application bundle and publishes a universal arm64/x86_64 build. The application checks `webapp/latest.json` for updates.

Update security roadmap: migrate the bootstrap updater to Sparkle 2 with HTTPS appcast + EdDSA signatures, then Developer ID/notarization when credentials are available.
