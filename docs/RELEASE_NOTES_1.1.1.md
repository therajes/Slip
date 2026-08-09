# Slip 1.1.1 — App selection that does something

Slip 1.1.1 turns the iPhone Apps inventory into a complete, explicit management workflow.

## What changed

- Every app row now has an unambiguous checkbox and selected-state styling.
- The selection bar supports Select Visible, Clear, Copy IDs, Refresh, and Uninstall.
- Refresh works on selected apps that have Slip Auto Refresh recipes.
- Uninstall uses the paired iPhone’s Installation Proxy and requires a destructive confirmation explaining that iOS deletes the app’s local data.
- Successfully removed apps also lose their matching Auto Refresh recipes, so Slip will not reinstall them later.
- Partial uninstall failures report exactly which bundle IDs need attention while successful removals remain reflected in the inventory.
- The destination preview is now an empty, neutral Liquid Glass iPhone icon. USB performs one clean insertion and settles; Network uses a restrained monochrome glass Wi-Fi badge. Reduce Motion remains authoritative.
- App-wide SF Symbols now share a dimensional glass treatment with hierarchical highlights and restrained shadows.
- Apple Accounts now show a profile name, email, dimensional avatar, selected status, and an optional local photo; Slip captures Apple’s verified first and last name after authentication when available.
- Destination identity now shows the iPhone’s personal name first and its detected model as a smaller parenthetical label.
- The Dynamic Island and notch match the iPhone’s neutral glass rim rather than using a black fill.

## Important limit

Slip lists user-installed apps only. Uninstall is intentionally unavailable until at least one app is explicitly selected. The downloadable build is development-signed and not notarized.
