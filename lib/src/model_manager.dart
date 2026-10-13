import 'anpr_config.dart';

/// Retained for API compatibility with scanner loading indicators.
/// Bundled models load locally, so download progress is not applicable.
class DownloadProgress {
  final int receivedBytes;
  final int totalBytes;
  final int currentFileBytes;
  final int currentFileTotalBytes;

  const DownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
    this.currentFileBytes = 0,
    this.currentFileTotalBytes = 0,
  });

  double? get fraction =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;
}

/// Asset names for the models bundled inside the Flutter package.
class ModelFiles {
  final String detectorPath;
  final String recognitionPath;

  const ModelFiles({
    required this.detectorPath,
    required this.recognitionPath,
  });
}

/// Resolves bundled model asset paths. No network, cache, checksum, or token
/// is used; the model files ship with this SDK in assets/models/.
class ModelManager {
  const ModelManager();

  Future<ModelFiles> loadModels({
    void Function(String status)? onStatus,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    onStatus?.call('Loading bundled TFLite models…');
    onProgress?.call(const DownloadProgress(receivedBytes: 1, totalBytes: 1));
    return const ModelFiles(
      detectorPath: AnprInternals.detectorAsset,
      recognitionPath: AnprInternals.recognitionAsset,
    );
  }
}
