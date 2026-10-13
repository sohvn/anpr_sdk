## 1.0.0

- Live plate scanning: `AnprScannerView` widget and headless `AnprScanner`.
- Still images: `AnprSdk.instance.recognizeImage()` / `recognizeImageFile()`.
- Encrypted model download on first run, cached for offline use.
- Confirmed-plate callback (`onPlate`) with confidence-weighted voting.
- Typed errors via `AnprException`.