import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

/// A cache-first TileProvider for flutter_map that stores downloaded
/// OSM tiles to local storage. When offline, tiles are served from cache.
/// Previously viewed map areas will display even without internet.
class CachedTileProvider extends TileProvider {
  static const int _maxCacheSizeMB = 200;
  static const int _maxCacheAgeDays = 30;
  static String? _cacheDirPath;
  static bool _cleanupDone = false;

  CachedTileProvider();

  static Future<String> getCacheDir() async {
    if (_cacheDirPath != null) return _cacheDirPath!;
    final dir = await getApplicationCacheDirectory();
    final tileDir = Directory('${dir.path}/map_tiles');
    if (!await tileDir.exists()) {
      await tileDir.create(recursive: true);
    }
    _cacheDirPath = tileDir.path;

    // Run cleanup once per app session
    if (!_cleanupDone) {
      _cleanupDone = true;
      _runCleanup(tileDir);
    }

    return _cacheDirPath!;
  }

  static Future<void> _runCleanup(Directory tileDir) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: _maxCacheAgeDays));
      int totalSize = 0;
      final files = <File>[];

      await for (final entity in tileDir.list(recursive: true)) {
        if (entity is File) {
          files.add(entity);
          final stat = await entity.stat();
          totalSize += stat.size;

          if (stat.modified.isBefore(cutoff)) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }

      // If cache exceeds limit, delete oldest files
      if (totalSize > _maxCacheSizeMB * 1024 * 1024) {
        final fileStats = <MapEntry<File, DateTime>>[];
        for (final f in files) {
          if (await f.exists()) {
            final stat = await f.stat();
            fileStats.add(MapEntry(f, stat.modified));
          }
        }
        fileStats.sort((a, b) => a.value.compareTo(b.value));

        int currentSize = totalSize;
        for (final entry in fileStats) {
          if (currentSize <= (_maxCacheSizeMB * 1024 * 1024 * 0.8).toInt()) break;
          try {
            final stat = await entry.key.stat();
            currentSize -= stat.size;
            await entry.key.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint("Tile cache cleanup error: $e");
    }
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final z = coordinates.z.toInt();
    final x = coordinates.x.toInt();
    final y = coordinates.y.toInt();
    final url = (options.urlTemplate ?? "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        .replaceAll('{z}', z.toString())
        .replaceAll('{x}', x.toString())
        .replaceAll('{y}', y.toString());

    return CachedNetworkTileImage(z: z, x: x, y: y, url: url);
  }
}

/// Custom ImageProvider that checks local cache before network.
class CachedNetworkTileImage extends ImageProvider<CachedNetworkTileImage> {
  final int z, x, y;
  final String url;

  const CachedNetworkTileImage({
    required this.z,
    required this.x,
    required this.y,
    required this.url,
  });

  @override
  Future<CachedNetworkTileImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<CachedNetworkTileImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    CachedNetworkTileImage key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(_loadAsync(decode));
  }

  Future<ImageInfo> _loadAsync(ImageDecoderCallback decode) async {
    final bytes = await _loadTileBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await decode(buffer);
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  Future<Uint8List> _loadTileBytes() async {
    final cacheDir = await CachedTileProvider.getCacheDir();
    final filePath = '$cacheDir/$z/$x/$y.png';
    final file = File(filePath);

    // Cache-first: try local file
    if (await file.exists()) {
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      } catch (_) {}
    }

    // Download from network
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'FinCell/1.0'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        // Save to cache in background
        try {
          final dir = Directory('$cacheDir/$z/$x');
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          await file.writeAsBytes(response.bodyBytes);
        } catch (_) {}

        return response.bodyBytes;
      }
    } catch (e) {
      debugPrint("Tile download failed ($z/$x/$y): $e");
    }

    // If both cache and network fail, return a transparent 1x1 PNG
    return _transparentPng;
  }

  static final Uint8List _transparentPng = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x00, 0x00, 0x02,
    0x00, 0x01, 0xE5, 0x27, 0xDE, 0xFC, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ]);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CachedNetworkTileImage &&
        other.z == z && other.x == x && other.y == y;
  }

  @override
  int get hashCode => Object.hash(z, x, y);
}
