enum AnprErrorCode {
  /// AnprSdk.instance.initialize() was not called (or has not finished).
  notInitialized,

  /// Reserved for compatibility with older SDK versions; local models need no internet.
  noInternet,

  /// Reserved for compatibility with older SDK versions; no API token is used.
  authFailed,

  /// Bundled TFLite models could not be loaded or initialized.
  modelSetupFailed,

  /// The bytes passed to recognizeImage() could not be decoded.
  invalidImage,

  /// The device has no camera.
  noCamera,

  /// The user denied camera permission.
  cameraPermissionDenied,

  /// Any other camera failure.
  cameraError,
}

class AnprException implements Exception {
  final AnprErrorCode code;
  final String message;
  final Object? cause;

  const AnprException(this.code, this.message, {this.cause});

  @override
  String toString() => 'AnprException(${code.name}): $message';
}
