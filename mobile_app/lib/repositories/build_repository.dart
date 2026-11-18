import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../models/build_artifact.dart';
import '../services/api_client.dart';

class BuildRepository {
  final ApiClient _api;

  BuildRepository(this._api);

  Future<List<BuildArtifact>> listBuilds(String workspace) async {
    final response = await _api.get('/api/builds', queryParameters: {'workspace': workspace});
    return (response.data as List)
        .map((e) => BuildArtifact.fromJson(e))
        .toList();
  }

  Future<void> downloadAndInstall(
    BuildArtifact build, {
    Function(int, int)? onProgress,
  }) async {
    final dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/${build.fileName}';
    final file = File(filePath);

    // APK Download Caching
    final isApk = build.fileName.toLowerCase().endsWith('.apk');
    final typeStr = isApk ? 'application/vnd.android.package-archive' : null;

    if (await file.exists()) {
      final stat = await file.stat();
      if (stat.size == build.sizeBytes) {
        // Assume it's the same file if size matches perfectly
        final result = await OpenFilex.open(filePath, type: typeStr);
        if (result.type != ResultType.done) {
          throw Exception(result.message.isNotEmpty ? result.message : 'Could not open installer');
        }
        return;
      }
    }

    try {
      await _api.download(
        build.downloadUrl,
        filePath,
        onReceiveProgress: onProgress,
      );
    } catch (e) {
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
      rethrow;
    }

    // Trigger Android package installer
    final result = await OpenFilex.open(filePath, type: typeStr);
    if (result.type != ResultType.done) {
      throw Exception(result.message.isNotEmpty ? result.message : 'Could not open installer');
    }
  }

  Future<void> downloadAndInstallFromPath(
    String rawPath,
    String fileName, {
    Function(int, int)? onProgress,
  }) async {
    final dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/$fileName';
    final file = File(filePath);

    final isApk = fileName.toLowerCase().endsWith('.apk');
    final typeStr = isApk ? 'application/vnd.android.package-archive' : null;

    try {
      await _api.download(
        '/api/builds/raw?path=${Uri.encodeComponent(rawPath)}',
        filePath,
        onReceiveProgress: onProgress,
      );
    } catch (e) {
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
      rethrow;
    }

    final result = await OpenFilex.open(filePath, type: typeStr);
    if (result.type != ResultType.done) {
      throw Exception(result.message.isNotEmpty ? result.message : 'Could not open installer');
    }
  }
}

final buildRepositoryProvider = Provider<BuildRepository>((ref) {
  return BuildRepository(ref.watch(apiClientProvider));
});
