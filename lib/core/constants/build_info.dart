/// Identifies the exact build a device is running. Injected by CI
/// (--dart-define=BUILD_LABEL=...) so 'which APK do you have' is
/// answerable at a glance; local builds report 'dev'.
const buildLabel = String.fromEnvironment(
  'BUILD_LABEL',
  defaultValue: 'dev',
);
