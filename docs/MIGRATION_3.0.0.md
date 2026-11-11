# Upgrade integrity

3.0 starts from owner-confirmed 2.9.2, preserving its capability-review acknowledgement and auto-accept behavior. Workspaces/deployment/catalog/backup formats, account sessions and Keychain references remain in place. Renewal evidence fields are additive. Legacy schedules lacking an approved source digest need explicit source review rather than silent approval of potentially changed bytes. Uncertain transfers remain pending until reconciliation.

Before replacing the local app, retain a private checkpoint of the app, Application Support data and preferences; do not export Keychain secrets. Compare content fingerprints during bundle replacement. Preserve the bundle ID and signing team when possible. No publication occurs until the owner tests and approves. Restore prior app bundle on replacement failure; never overwrite new user data blindly.
