## 1.0.0

- Initial release.
- Live plate scanning: `AnprScannerView` widget and headless `AnprScanner`.
- Still images: `AnprSdk.instance.recognizeImage()` / `recognizeImageFile()`.
- Models download once on first run and are cached for fully offline use.
- Confirmed-plate callback (`onPlate`) with confidence-weighted voting.
- Typed errors via `AnprException` / `AnprErrorCode`.
- `AnprSdkConfig` for tuning thresholds, intervals and voting.