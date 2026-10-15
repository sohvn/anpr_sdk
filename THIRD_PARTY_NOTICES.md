# Third-party notices

## The SDK code

The `anpr_sdk` source code in this package is licensed under the MIT License
(see `LICENSE`).

## The models (downloaded at runtime, not part of this package)

This package contains **no model files**. On first run it downloads them from
<https://github.com/sohvn/anpr-models/releases>. The models have separate
licenses, which apply to the model files and to anything that distributes them:

| Model | Based on | License |
| --- | --- | --- |
| Plate detector (`best.onnx`) | Ultralytics YOLO | GNU AGPL-3.0 |
| Plate text recognizer (`anpr_ocr_f16.onnx`, `en_dict.txt`) | PaddleOCR | Apache-2.0 |

Please read the full terms at
<https://github.com/sohvn/anpr-models/blob/main/NOTICE.md> before using the
SDK in a product. In particular, the AGPL-3.0 terms for the detector may
affect how you can distribute an app that uses it.

## Runtime dependencies

This package depends on `camera`, `flutter_onnxruntime`, `http` and
`path_provider`. Each is licensed by its own authors; see their pages on
pub.dev.