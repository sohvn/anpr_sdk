# ANPR SDK for Flutter (TensorFlow Lite)

On-device automatic number-plate detection and recognition for Flutter apps. The detector and recognizer are bundled as TFLite assets inside this package. The SDK does not download models, call external services, require an API token, or compute model checksums at runtime.

## Models bundled with the SDK

- `assets/models/plate_det_int8_dynamic.tflite` — number-plate detector.
- `assets/models/plate_rec_float16.tflite` — plate-text recognizer.


## Quick start

```dart
import 'package:flutter/widgets.dart';
import 'package:anpr_sdk/anpr_sdk.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AnprSdk.instance.initialize();
  runApp(const MyApp());
}
```

Add the scanner to a widget:

```dart
AnprScannerView(
  onPlate: (result) {
    debugPrint('Plate: ${result.plateNumber}');
  },
)
```

Recognize a still image:

```dart
final result = await AnprSdk.instance.recognizeImage(imageBytes);
debugPrint(result?.plateNumber ?? 'No plate recognized');
```

## Offline and model security

Both model files are packaged as Flutter assets and loaded locally by `tflite_flutter`. No GitHub model repository, release asset, model download, SHA-256 configuration, or internet access is needed for model loading. As with any bundled binary, users can inspect or extract model assets from an application package; bundling is distribution, not encryption or tamper-proofing.

## Platform setup

Configure camera permissions in the host app as required by Flutter's `camera` package. The TFLite runtime and native build requirements depend on the Flutter, Dart, Android Gradle, Android NDK, and iOS deployment versions in the consuming app.

The `tooling/tflite_reference/` directory contains supplied Python reference and validation scripts. These are development tools and are not runtime dependencies of the Flutter SDK.

## License

See `LICENSE` for the SDK source license. The SDK source license does not automatically grant rights to model weights or third-party dependencies. Verify the model and dependency licenses before redistribution or commercial use.
