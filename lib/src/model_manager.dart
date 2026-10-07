import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
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

/// Owns model authorization, encrypted downloads, AES-GCM decryption and
/// version-keyed local caching.
///
/// Authorization is isolated here so the Bearer token can later be replaced by
/// Play Integrity / App Attest without touching the rest of the SDK.
class ModelManager {
  final String apiToken;
  final String workerUrl;

  ModelManager({required this.apiToken, required this.workerUrl});

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

    // Cached: works fully offline, token not needed.
    if (await yoloFile.exists() &&
        await ocrFile.exists() &&
        await dictFile.exists()) {
      onStatus?.call('READY');
      return files;
    }

    if (apiToken.trim().isEmpty) {
      throw const AnprException(
        AnprErrorCode.authFailed,
        'apiToken is empty. Pass your token to AnprSdk.instance.initialize().',
      );
    }

    onStatus?.call('Getting things ready…');
    final secretKey = await _fetchKey();
    final aes = AesGcm.with256bits();

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
        await _downloadDecryptFile(
          url: target.url,
          destination: target.destination,
          aes: aes,
          secretKey: secretKey,
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

  Future<SecretKey> _fetchKey() async {
    late final http.Response response;
    try {
      response = await http.post(
        Uri.parse('$workerUrl/v1/model-key'),
        headers: {
          'Authorization': 'Bearer $apiToken',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 20));
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
    } catch (e) {
      throw AnprException(
        AnprErrorCode.modelSetupFailed,
        'Could not connect to the model service.',
        cause: e,
      );
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const AnprException(
        AnprErrorCode.authFailed,
        'The API token is invalid or has expired.',
      );
    }
    if (response.statusCode != 200) {
      throw AnprException(
        AnprErrorCode.modelSetupFailed,
        'Model authorization failed (${response.statusCode}).',
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic> || json['ok'] != true) {
      throw const AnprException(
        AnprErrorCode.modelSetupFailed,
        'Invalid model authorization response.',
      );
    }

    final returnedVersion = json['modelVersion']?.toString();
    if (returnedVersion != AnprInternals.modelVersion) {
      throw AnprException(
        AnprErrorCode.modelSetupFailed,
        'Model version mismatch: server=$returnedVersion, '
        'sdk=${AnprInternals.modelVersion}. Update the SDK.',
      );
    }

    final keyB64 = json['key']?.toString();
    if (keyB64 == null || keyB64.isEmpty) {
      throw const AnprException(
        AnprErrorCode.modelSetupFailed,
        'Model key missing from server response.',
      );
    }

    final expiresAt = (json['expiresAt'] as num?)?.toInt();
    if (expiresAt != null &&
        DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt) {
      throw const AnprException(
        AnprErrorCode.authFailed,
        'Model authorization has expired.',
      );
    }

    final keyBytes = base64Decode(keyB64);
    if (keyBytes.length != 32) {
      throw AnprException(
        AnprErrorCode.modelSetupFailed,
        'Invalid AES-256 key length: ${keyBytes.length} bytes.',
      );
    }
    return SecretKey(keyBytes);
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

  Future<void> _downloadDecryptFile({
    required String url,
    required File destination,
    required AesGcm aes,
    required SecretKey secretKey,
    required int knownTotalBytes,
    required int completedBytesBefore,
    required int totalBytes,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final client = http.Client();
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
      final builder = BytesBuilder(copy: false);
      var received = 0;

      await for (final chunk in response.stream) {
        builder.add(chunk);
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

      final encrypted = builder.takeBytes();
      if (encrypted.length < 12 + 16) {
        throw const AnprException(
          AnprErrorCode.modelSetupFailed,
          'Encrypted model is too small.',
        );
      }

      // Layout: [12-byte nonce][ciphertext][16-byte GCM tag]
      final nonce = encrypted.sublist(0, 12);
      final cipherText = encrypted.sublist(12, encrypted.length - 16);
      final macBytes = encrypted.sublist(encrypted.length - 16);
      final box = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));
      final plaintext = await aes.decrypt(box, secretKey: secretKey);

      final temp = File('${destination.path}.tmp');
      try {
        await temp.writeAsBytes(plaintext, flush: true);
        await temp.rename(destination.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    } finally {
      client.close();
    }
  }
}
