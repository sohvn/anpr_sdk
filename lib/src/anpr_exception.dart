enum AnprErrorCode {
  /// AnprSdk.instance.initialize() was not called (or has not finished).
  notInitialized,

  /// First-run model download needs internet and none was available.
  noInternet,

  /// Models could not be downloaded or loaded.
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
