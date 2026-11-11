# Slip 3.0 user test checklist

1. Confirm existing accounts, library, presets, subscriptions, devices and renewal entries survived. Inspect an IPA offline without signing in.
2. Refresh the app that previously prompted for capabilities. Confirm accepting/auto-accepting no longer reports cancellation. Test explicit cancellation separately.
3. In Auto Refresh, approve the saved source/options where requested. Run Check Background Readiness; a pass describes readiness, not a completed renewal. Verify a manual refresh on the intended phone and distinguish confirmed/estimated expiry.
4. Enable the optional menu companion. Test Open Slip, Install IPA (review only), Refresh Due, pause/resume and close-window versus Quit. Independently test GUI login/background/notification preferences; none should silently enable another.
5. Exercise missing phone, missing IPA, offline network, USB/Wi-Fi change and sleep/wake. Check waiting/backoff/authentication/pending statuses and next actions; no duplicate install or false success.
6. Test notifications enabled/denied, quiet hours and a notification click into the relevant renewal issue. No banner should disclose account/device identity or request a personal code headlessly.
7. Test existing SMS/trusted-device 2FA privately; never send codes/passwords to the agent. Background interaction-required cases must wait for foreground authentication.
8. Check keyboard, VoiceOver, narrow layout, Reduce Motion/Transparency and non-English system settings. Unreviewed translations must fall back to English.
9. Keep a multiday record of due renewals with Mac awake/device reachable versus blocked. Do not treat a readiness check as success. Confirm verified device/version outcome after each attempt.

Return the release flag only after satisfactory local testing. Production signing/notarization and clean-machine Gatekeeper still require external credentials/evidence. No automatic application updater is enabled; current manual replacement retains checkpoints and credentials.
