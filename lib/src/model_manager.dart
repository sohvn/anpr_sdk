import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'anpr_config.dart';
import 'anpr_exception.dart';

class ModelFiles {
  final String yoloPath;
  final String ocrPath;
  final String dictPath;

  const ModelFiles({
    required this.yoloPath,
    required this.ocrPath,
    required this.dictPath,
  });
}

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

  /// 0..1, or null when the total size is unknown.
  double? get fraction =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;
}

class _DownloadTarget {
  final String url;
  final File destination;

  const _DownloadTarget(this.url, this.destination);
}

/// Downloads the plain (unencrypted) models from the GitHub release on first
/// run and caches them locally, keyed by model version.
class ModelManager {
  ModelManager();

  Future<Directory> _modelDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory(
      '${base.path}${Platform.pathSeparator}models_${AnprInternals.modelVersion}',
    );
  }

  /// Removes cached models (used to recover from corrupt files).
  Future<void> clearCache() async {
    final dir = await _modelDir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<ModelFiles> loadModels({
    void Function(String status)? onStatus,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final modelDir = await _modelDir();
    await modelDir.create(recursive: true);

    final sep = Platform.pathSeparator;
    final yoloPath = '${modelDir.path}$sep${AnprInternals.yoloFileName}';
    final ocrPath = '${modelDir.path}$sep${AnprInternals.ocrFileName}';
    final dictPath = '${modelDir.path}$sep${AnprInternals.dictFileName}';

    final yoloFile = File(yoloPath);
    final ocrFile = File(ocrPath);
    final dictFile = File(dictPath);

    final files = ModelFiles(
      yoloPath: yoloPath,
      ocrPath: ocrPath,
      dictPath: dictPath,
    );

    // Cached: works fully offline.
    if (await yoloFile.exists() &&
        await ocrFile.exists() &&
        await dictFile.exists()) {
      onStatus?.call('READY');
      return files;
    }

    onStatus?.call('Getting required files…');
    final downloads = <_DownloadTarget>[
      _DownloadTarget(AnprInternals.yoloUrl, yoloFile),
      _DownloadTarget(AnprInternals.ocrUrl, ocrFile),
      _DownloadTarget(AnprInternals.dictUrl, dictFile),
    ];

    final totals = await _resolveDownloadTotals(downloads);
    final totalBytes = totals.fold<int>(0, (sum, v) => sum + v);
    var completedBytes = 0;

    onProgress?.call(DownloadProgress(receivedBytes: 0, totalBytes: totalBytes));

    for (var i = 0; i < downloads.length; i++) {
      final target = downloads[i];
      onStatus?.call(i == downloads.length - 1
          ? 'Almost ready…'
          : 'Getting things ready…');
      try {
        await _downloadFile(
          url: target.url,
          destination: target.destination,
          knownTotalBytes: totals[i],
          completedBytesBefore: completedBytes,
          totalBytes: totalBytes,
          onProgress: onProgress,
        );
      } on AnprException {
        rethrow;
      } catch (e) {
        throw AnprException(
          AnprErrorCode.modelSetupFailed,
          'Could not prepare the required files.',
          cause: e,
        );
      }
      completedBytes += totals[i];
      onProgress?.call(DownloadProgress(
        receivedBytes: completedBytes,
        totalBytes: totalBytes,
      ));
    }

    onStatus?.call('READY');
    return files;
  }

  Future<List<int>> _resolveDownloadTotals(
    List<_DownloadTarget> downloads,
  ) async {
    final totals = <int>[];
    final client = http.Client();
    try {
      for (final target in downloads) {
        try {
          final response = await client
              .head(Uri.parse(target.url))
              .timeout(const Duration(seconds: 20));
          totals.add(response.contentLength ?? 0);
        } catch (_) {
          // A missing Content-Length is fine; progress falls back to unknown.
          totals.add(0);
        }
      }
    } finally {
      client.close();
    }
    return totals;
  }

  Future<void> _downloadFile({
    required String url,
    required File destination,
    required int knownTotalBytes,
    required int completedBytesBefore,
    required int totalBytes,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final client = http.Client();
    final temp = File('${destination.path}.tmp');
    IOSink? sink;
    try {
      late final http.StreamedResponse response;
      try {
        final request = http.Request('GET', Uri.parse(url));
        request.headers['Accept'] = 'application/octet-stream';
        response =
            await client.send(request).timeout(const Duration(minutes: 2));
      } on SocketException {
        throw const AnprException(
          AnprErrorCode.noInternet,
          'Internet connection required for first-time setup.',
        );
      } on TimeoutException {
        throw const AnprException(
          AnprErrorCode.noInternet,
          'Internet connection required for first-time setup.',
        );
      } on http.ClientException {
        throw const AnprException(
          AnprErrorCode.noInternet,
          'Internet connection required for first-time setup.',
        );
      }

      if (response.statusCode != 200) {
        throw AnprException(
          AnprErrorCode.modelSetupFailed,
          'Model download failed (${response.statusCode}).',
        );
      }

      final responseLength = response.contentLength ?? 0;
      final expectedBytes =
          responseLength > 0 ? responseLength : knownTotalBytes;

      // Stream straight to disk (models are large; no need to hold them in RAM).
      sink = temp.openWrite();
      var received = 0;

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        final effectiveTotal =
            totalBytes > 0 ? totalBytes : (expectedBytes > 0 ? expectedBytes : 0);
        onProgress?.call(DownloadProgress(
          receivedBytes: completedBytesBefore + received,
          totalBytes: effectiveTotal,
          currentFileBytes: received,
          currentFileTotalBytes: expectedBytes,
        ));
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (received == 0 || (responseLength > 0 && received != responseLength)) {
        throw const AnprException(
          AnprErrorCode.modelSetupFailed,
          'Model download was incomplete.',
        );
      }

      await temp.rename(destination.path);
    } finally {
      client.close();
      try {
        await sink?.close();
      } catch (_) {}
      if (await temp.exists()) await temp.delete();
    }
  }
}
