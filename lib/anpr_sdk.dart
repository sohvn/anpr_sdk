/// Plug-and-play number plate detection and recognition.
///
/// ```dart
/// await AnprSdk.instance.initialize(apiToken: '...');
///
/// AnprScannerView(onPlate: (r) => print(r.plateNumber));
/// ```
library;

// Handy camera types used by AnprScanner so apps don't need their own import.
export 'package:camera/camera.dart' show ResolutionPreset, CameraLensDirection;

export 'src/anpr_config.dart' show AnprSdkConfig;
export 'src/anpr_exception.dart';
export 'src/anpr_result.dart';
export 'src/anpr_scanner.dart' show AnprScanner, AnprScannerStatus;
export 'src/anpr_sdk_base.dart' show AnprSdk, AnprSdkStatus;
export 'src/model_manager.dart' show DownloadProgress;
export 'src/widgets/anpr_scanner_view.dart' show AnprScannerView;
