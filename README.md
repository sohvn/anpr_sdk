# anpr_sdk

Plug-and-play **number plate detection and recognition (ANPR)** for Flutter.

Drop in one widget and get live plate reads from the camera, or pass in a photo
and get the plate text back. Everything runs **on-device** with ONNX models:
no per-scan API calls, no server, and it works offline after the first launch.

## Features

- **Live scanning**: `AnprScannerView` is a ready-made camera preview with a
  bounding box and a confirmed-plate callback.
- **Headless scanning**: `AnprScanner` gives you the camera and result streams
  so you can build your own UI.
- **Still images**: `recognizeImage()` / `recognizeImageFile()` for gallery
  photos, uploads or snapshots.
- **Stable results**: confidence-weighted voting across frames, so a plate is
  only reported once it has been read consistently.
- **One-time model download**: models are fetched on first run, cached on the
  device, and then work fully offline.
- **Typed errors**: `AnprException` with an `AnprErrorCode` you can switch on.
- **Tunable**: thresholds, intervals and voting through `AnprSdkConfig`.

## Platform support

**Android only** for now. iOS has not been tested and is not officially
supported yet.

## Installation

```yaml
dependencies:
  anpr_sdk: ^1.0.0
```

```sh
flutter pub get
```

## Android setup

Add the permissions to `android/app/src/main/AndroidManifest.xml`
(outside the `<application>` tag):

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.CAMERA"/>
```

`INTERNET` is only needed for the first-run model download.

If your build fails with a minimum SDK error, raise `minSdk` in
`android/app/build.gradle(.kts)`. The `camera` plugin needs 21 or higher, and
`flutter_onnxruntime` may need a higher value (24 is a safe choice).

## Quick start

Call `initialize()` once, as early as possible, then show the scanner.

```dart
import 'dart:async';

import 'package:anpr_sdk/anpr_sdk.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Starts the model download (first run only) and loads the models.
  // No need to await it: AnprScannerView shows progress by itself.
  unawaited(
    AnprSdk.instance
        .initialize()
        .catchError((Object e) => debugPrint('ANPR init failed: $e')),
  );

  runApp(const MaterialApp(home: ScanPage()));
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  String? _plate;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          AnprScannerView(
            onPlate: (r) => setState(() => _plate = r.plateNumber),
          ),
          SafeArea(
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              color: Colors.white,
              child: Text(_plate ?? 'Point the camera at a number plate'),
            ),
          ),
        ],
      ),
    );
  }
}
```

## Usage

### 1. Initialize

```dart
await AnprSdk.instance.initialize();
```

- Safe to call more than once: it returns immediately when ready, and
  concurrent calls share a single run.
- The first run downloads the models over the internet and caches them. Later
  runs load from the cache and work **offline**.
- Throws an `AnprException` on failure. Call it again to retry.

Pass a config to tune behaviour:

```dart
await AnprSdk.instance.initialize(
  config: const AnprSdkConfig(
    detectionThreshold: 0.40,
    confirmReads: 3,
  ),
  onStatus: (s) => debugPrint('ANPR: $s'),
);
```

You can also watch the state to build your own loading screen:

```dart
ValueListenableBuilder<AnprSdkStatus>(
  valueListenable: AnprSdk.instance.status,
  builder: (context, status, _) {
    // uninitialized, initializing, ready, error
    return Text(status.name);
  },
);

// First-run download progress (null when not downloading)
ValueListenableBuilder<DownloadProgress?>(
  valueListenable: AnprSdk.instance.downloadProgress,
  builder: (context, p, _) => LinearProgressIndicator(value: p?.fraction),
);
```

### 2. Live scanning with the widget

```dart
AnprScannerView(
  onPlate: (AnprResult r) => print('${r.plateNumber} (${r.ocrConfidence})'),
  showBoundingBox: true,
  boxColor: Colors.green,
  fit: BoxFit.cover,
)
```

Customise what the user sees:

```dart
AnprScannerView(
  onPlate: (r) => save(r.plateNumber!),
  loadingBuilder: (context, progress) =>
      Center(child: CircularProgressIndicator(value: progress)),
  errorBuilder: (context, error, retry) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(error.message),
        TextButton(onPressed: retry, child: const Text('Retry')),
      ],
    ),
  ),
  // Draw anything on top of the preview using the live (per-frame) result.
  overlayBuilder: (context, live) => Align(
    alignment: Alignment.bottomCenter,
    child: Text(live.plateNumber ?? '…'),
  ),
)
```

`onPlate` fires only for **confirmed** plates: the same plate must be read
`confirmReads` times (default 2). A plate that stays in view is reported again
only after `repeatCooldown` (default 5 s); a plate that leaves the view and
returns is reported again immediately.

### 3. Live scanning without the widget (headless)

Use `AnprScanner` when you want your own camera UI or want to start and stop
scanning from code.

```dart
final scanner = AnprScanner(
  lensDirection: CameraLensDirection.back,
  resolution: ResolutionPreset.high,
);

// Confirmed plates
final sub = scanner.plates.listen((r) => print(r.plateNumber));

// Per-frame updates (box, current text, timings)
scanner.live.addListener(() => print(scanner.live.value));

await scanner.start();   // never throws: check scanner.status / scanner.error
// ...
await scanner.stop();    // releases the camera, can start() again
await sub.cancel();
await scanner.dispose(); // when finished for good
```

You can also hand your own scanner to the widget to control it from outside.
The view then will **not** dispose it for you:

```dart
final scanner = AnprScanner();
AnprScannerView(scanner: scanner, onPlate: (r) {});
```

The scanner pauses the camera automatically when the app goes to the
background and resumes when it comes back.

### 4. Still images

```dart
final AnprResult? result =
    await AnprSdk.instance.recognizeImage(bytes);      // Uint8List (JPEG/PNG/…)

final AnprResult? fromFile =
    await AnprSdk.instance.recognizeImageFile(File(path));

if (result == null) {
  // No plate found
} else if (result.plateNumber == null) {
  // A plate was found but its text could not be read confidently
} else {
  print(result.plateNumber); // e.g. MH12AB1234
}
```

The image must be upright. EXIF rotation is not applied, so rotate photos
from a camera first if needed.

### 5. Handle errors

```dart
try {
  await AnprSdk.instance.initialize();
} on AnprException catch (e) {
  switch (e.code) {
    case AnprErrorCode.noInternet:
      // First-time setup needs a connection
      break;
    case AnprErrorCode.modelSetupFailed:
      // Download or model loading failed: retry
      break;
    default:
      debugPrint(e.toString());
  }
}
```

| Code | Meaning |
| --- | --- |
| `notInitialized` | `initialize()` was not called, or has not finished |
| `noInternet` | First-run model download needs a connection |
| `modelSetupFailed` | Models could not be downloaded or loaded |
| `invalidImage` | The bytes passed to `recognizeImage()` could not be decoded |
| `noCamera` | The device has no camera |
| `cameraPermissionDenied` | The user denied camera permission |
| `cameraError` | Any other camera failure |

## Reading a result

`AnprResult` fields:

| Field | Type | Description |
| --- | --- | --- |
| `plateNumber` | `String?` | Upper-case letters and digits only, e.g. `MH12AB1234`. Null if nothing was read |
| `ocrConfidence` | `double` | Confidence of the latest text read, 0 to 1 |
| `detectionConfidence` | `double` | Confidence of the plate box, 0 to 1 |
| `box` | `Rect?` | Plate box in pixels of the upright frame |
| `frameSize` | `Size` | Size of the frame the `box` refers to |
| `isConfirmed` | `bool` | True when the same plate was read enough times |
| `timestamp` | `DateTime` | When the result was produced |
| `detectionMs`, `ocrMs` | `double` | Timings in milliseconds, handy for debugging |

## Configuration

All fields of `AnprSdkConfig` are optional.

| Option | Default | Description |
| --- | --- | --- |
| `detectionThreshold` | `0.35` | Minimum confidence to accept a plate box |
| `detectionInterval` | `150 ms` | Minimum gap between detection runs |
| `ocrInterval` | `400 ms` | Minimum gap between OCR runs |
| `ocrMinConfidence` | `0.55` | Text reads below this are ignored |
| `ocrMinLength` | `3` | Text reads shorter than this are ignored |
| `boxGrace` | `500 ms` | Keep the box on screen this long if a frame misses |
| `textClear` | `3 s` | Clear the plate text if no plate was seen for this long |
| `voteWindow` | `2500 ms` | Window used to vote between noisy reads |
| `voteMaxReads` | `7` | Max recent reads kept for voting |
| `confirmReads` | `2` | Reads needed before a plate is confirmed |
| `repeatCooldown` | `5 s` | A plate that stays in view is reported again after this |

Raise `confirmReads` and `ocrMinConfidence` for fewer false reads. Lower them
for faster results.

## How the models are delivered

The package ships no model files. On first run it downloads three files from
the project's GitHub release and stores them in the app's support directory
(`models_<version>`):

- `best.onnx`: plate detector
- `anpr_ocr_f16.onnx`: plate text recognizer
- `en_dict.txt`: character dictionary

After that the SDK works offline. If a cached model fails to load, it is
deleted and downloaded again once automatically.

## Tips for good results

- Keep the plate fully inside the frame, roughly facing the camera.
- Good light matters more than resolution. Avoid strong glare on the plate.
- Use `ResolutionPreset.high` for distant plates; `medium` on low-end phones
  if frames are slow.
- Call `AnprSdk.instance.dispose()` only if you want to free the native
  models; call `initialize()` again to reuse the SDK.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Spinner never finishes on first run | The device needs internet on first launch. Check `AnprSdk.instance.lastError` |
| "Model download failed (404)" | The model files are missing from the release. Check the package version |
| Black screen or camera error on Android | Add the `CAMERA` permission and accept the runtime prompt |
| Wrong text read | Raise `confirmReads` / `ocrMinConfidence`, improve lighting |

## Example

A full runnable app is in the [`example/`](example) folder.

## Issues and contributions

Bug reports and pull requests are welcome at
[github.com/sohvn/anpr_sdk](https://github.com/sohvn/anpr_sdk/issues).

## License

The SDK source code is released under the **MIT License**. See [LICENSE](LICENSE).

The package ships no models. The models it downloads at runtime have their own
licenses: the plate detector is based on Ultralytics YOLO (**AGPL-3.0**) and the
text recognizer on PaddleOCR (**Apache-2.0**). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and read the model terms before
using the SDK in a product.