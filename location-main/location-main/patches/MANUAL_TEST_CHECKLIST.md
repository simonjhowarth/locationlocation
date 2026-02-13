Manual Test Checklist — Location Tracking App
===========================================

Purpose: step through runtime scenarios to validate permissions, continuous tracking, map updates, and sound-only mode.

Preparation
- Run `flutter pub get` and build for a physical device or emulator with location support.
- Install app on Android and iOS test devices/emulators.

1) Permission flow
- Launch the app fresh (uninstalled state). Verify app requests location permission.
- Approve `Allow while using the app`. The app should show the permission banner offering `Request Always`.
- Tap `Request Always` and approve. Verify the banner goes away and logs show permission result.
- If you deny forever, verify the app opens App Settings when pressing the request button.

2) Initial location and map
- After granting permission, the map should center on current location and display coordinates on screen.
- Check the logs panel (toggle `Show Logs`) to confirm an initial position log and subsequent position updates.

3) Continuous updates and smoothing
- Move the device (or use emulator mock locations). Verify new coordinates appear and the camera animates to the new location.
- Confirm updates are not overly noisy; the app uses a `distanceFilter` of 5 meters — small jitter should be filtered.

4) Sound-only mode
- Switch to `Sound Only` mode and enable sound. Confirm a short beep plays on position updates.

5) Background tracking (manual)
- With `Always` permission granted, background the app or lock the device and walk a short distance. Re-open app and confirm recent location updates were received.
- Note: background behavior differs across Android/iOS and may require foreground services or platform-specific setup.

6) Edge cases and errors
- Turn off location services on device and verify the app logs errors and guides the user to enable location.
- Revoke permissions from OS-level settings and re-run flows to ensure the app behaves gracefully.

7) CI verification
- Push a branch/PR and verify the GitHub Actions `Flutter Tests` workflow runs and completes.

Notes
- For iOS, ensure `NSLocationAlwaysAndWhenInUseUsageDescription` and `UIBackgroundModes: location` are set (Info.plist).
- For Android 10+, ensure `ACCESS_BACKGROUND_LOCATION` is declared and request at runtime when appropriate.
