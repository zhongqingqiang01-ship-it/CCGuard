# CCGuard development rules

This is a macOS Swift package. Application adapters are in Sources/CCGuardApp; pure policy is in Sources/CCGuardCore. Run scripts/check.sh with Node.js 22+ and Swift 6+. Build with scripts/build.sh; output is dist/CC登录器.app. Version metadata is Resources/Info.plist.

Startup gates run in order. Score must exceed 90. Reputation/residential/region checks run only at startup. Runtime uses fresh background requests and DNS/WebRTC probes without page navigation. Domestic IPv4 can differ under split routing; only Claude and Cloudflare exits must match the configured IPv4. Confirmed violations revoke immediately; unavailable observations retry every 10 seconds for at most 120 seconds without partial results extending the deadline.

Keep process identity checks and descendant coverage. Real VS Code startup/termination tests require explicit user authorization and saved work; use scripts/verify-watchdog.py isolated fixtures by default. No real network, external accounts or GUI automation are used in default tests.

Never commit personal settings, logs, captures, build caches, credentials, certificates, archives or locally compiled bundles. Public fixtures use documentation IP ranges. The release is ad-hoc signed and not Apple-notarized. Verify privacy and CI before publishing.
