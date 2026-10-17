import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../src/rust/api.dart';

/// One verified extraction generation. Existing generations are immutable:
/// saved projects may still reference their text and resource paths.
class EpubImportBundle {
  const EpubImportBundle(this.textPath, this.resources);
  final String textPath;
  final Map<String, dynamic> resources;
}

typedef EpubTextExtractor = Future<String> Function({
  required String sourcePath,
  required String outputPath,
});
typedef EpubResourceExtractor = Future<String> Function({
  required String sourcePath,
  required String resourceDir,
});

class EpubImportCache {
  EpubImportCache({
    required this.root,
    this.extractText = importEpubText,
    this.extractResources = importEpubResources,
    this.publishReceipt = _publishReceipt,
  });

  final Directory root;
  final EpubTextExtractor extractText;
  final EpubResourceExtractor extractResources;
  final Future<void> Function(File pending, String destination) publishReceipt;
  static Future<void> _publishReceipt(File pending, String destination) async {
    await pending.rename(destination);
  }

  static const _maxBytes = 256 * 1024 * 1024;

  void _check(bool Function() cancelled) {
    if (cancelled()) throw const FormatException('导入已取消。');
  }

  Future<String> _hash(File file, bool Function() cancelled) async {
    _check(cancelled);
    final digest = await sha256
        .bind(
          file.openRead().map((bytes) {
            _check(cancelled);
            return bytes;
          }),
        )
        .first;
    _check(cancelled);
    return digest.toString();
  }

  Future<EpubImportBundle> read(File source, bool Function() cancelled) async {
    _check(cancelled);
    if (await source.length() > _maxBytes) {
      throw const FormatException('EPUB 文件上限为 256 MiB。');
    }
    // Hashing and snapshot creation use asynchronous bounded streams.
    // Both native extractors see the same private file, even if the user
    // replaces the original while import is in progress.
    final sourceHash = await _hash(source, cancelled);
    final identity = sha256
        .convert(
          utf8.encode(
            'epub-cache-v4\n${p.normalize(source.absolute.path)}\n$sourceHash',
          ),
        )
        .toString();
    final bucket = Directory(
      p.join(root.path, 'v4-${identity.substring(0, 32)}'),
    );
    await bucket.create(recursive: true);
    final receiptFile = File(p.join(bucket.path, 'current.json'));
    final cached = await _reuse(receiptFile, source, sourceHash, cancelled);
    if (cached != null) return cached;
    // Some Windows filesystem providers reject even same-directory rename.
    // Their immutable receipts are independent of the mutable fast-path index.
    await for (final entry in bucket.list(followLinks: false)) {
      _check(cancelled);
      if (entry is! File ||
          !RegExp(r'^ready-g-[A-Za-z0-9_-]+\.json$')
              .hasMatch(p.basename(entry.path))) {
        continue;
      }
      final ready = await _reuse(entry, source, sourceHash, cancelled);
      if (ready != null) return ready;
    }

    final generation = await bucket.createTemp('g-');
    final snapshot = File(p.join(generation.path, 'source.epub'));
    try {
      final writer = await snapshot.open(mode: FileMode.writeOnly);
      var count = 0;
      try {
        await for (final bytes in source.openRead()) {
          _check(cancelled);
          count += bytes.length;
          if (count > _maxBytes) {
            throw const FormatException('EPUB 文件上限为 256 MiB。');
          }
          await writer.writeFrom(bytes);
        }
      } finally {
        await writer.close();
      }
      if (await _hash(snapshot, cancelled) != sourceHash) {
        throw const FormatException('读取期间原 EPUB 已改变，请重新导入。');
      }
      final text = File(p.join(generation.path, 'book.txt'));
      final resourcesDir = Directory(p.join(generation.path, 'resources'));
      await extractText(sourcePath: snapshot.path, outputPath: text.path);
      _check(cancelled);
      final resources = jsonDecode(
        await extractResources(
          sourcePath: snapshot.path,
          resourceDir: resourcesDir.path,
        ),
      ) as Map<String, dynamic>;
      _check(cancelled);
      resources['source_path'] = source.path;
      final manifest = File(p.join(resourcesDir.path, 'manifest.json'));
      await manifest.writeAsString(jsonEncode(resources), flush: true);
      final paths = _paths(
        generation.path,
        text.path,
        manifest.path,
        resources,
      );
      final hashes = <String, String>{};
      for (final path in paths) {
        hashes[p.relative(path, from: generation.path)] = await _hash(
          File(path),
          cancelled,
        );
      }
      // No receipt is published for cancelled or interrupted generations.
      // Recheck the origin as well; users should not silently import an older
      // snapshot when they replaced the source during extraction.
      if (await _hash(source, cancelled) != sourceHash) {
        throw const FormatException('提取期间原 EPUB 已改变，请重新导入。');
      }
      final pending = File(p.join(generation.path, 'receipt.pending'));
      final receiptJson = jsonEncode({
        'version': 4,
        'source_path': source.path,
        'source_sha256': sourceHash,
        'generation': p.basename(generation.path),
        'files': hashes,
      });
      await pending.writeAsString(receiptJson, flush: true);
      _check(cancelled);
      for (var attempt = 0; ; attempt++) {
        _check(cancelled);
        if (attempt > 0 && await _hash(source, cancelled) != sourceHash) {
          throw const FormatException('发布缓存期间原 EPUB 已改变，请重新导入。');
        }
        try {
          await publishReceipt(pending, receiptFile.path);
          break;
        } on FileSystemException catch (error) {
          if (Platform.isWindows && error.osError?.errorCode == 17) {
            // Never emulate rename by overwriting current.json. This unique
            // generation owns a unique receipt; no published file is replaced.
            // Readers accept it only when the whole JSON, manifest, all file
            // hashes and current source hash agree. Partial writes are ignored.
            _check(cancelled);
            if (await _hash(source, cancelled) != sourceHash) {
              throw const FormatException('发布缓存期间原 EPUB 已改变，请重新导入。');
            }
            final ready = File(
              p.join(bucket.path, 'ready-${p.basename(generation.path)}.json'),
            );
            await ready.writeAsString(receiptJson, flush: true);
            final verified = await _reuse(ready, source, sourceHash, cancelled);
            if (verified == null) {
              throw const FormatException('缓存写入后校验失败，请重新导入。');
            }
            return verified;
          }
          // Windows may deny replacing a receipt while a concurrent reader or
          // publisher holds it. Reuse only a fully authenticated winning bundle.
          if (!Platform.isWindows ||
              ![5, 32, 33].contains(error.osError?.errorCode)) {
            rethrow;
          }
          final winner = await _reuse(
            receiptFile,
            source,
            sourceHash,
            cancelled,
          );
          if (winner != null) return winner;
          if (attempt >= 5) rethrow;
          await Future<void>.delayed(
            Duration(milliseconds: 20 * (attempt + 1)),
          );
        }
      }
      return EpubImportBundle(text.path, resources);
    } finally {
      // This private input is never referenced by projects or manifests.
      // Keep extraction generations (including older damaged files) intact.
      if (await snapshot.exists()) await snapshot.delete();
    }
  }

  List<String> _paths(
    String generation,
    String text,
    String manifest,
    Map<String, dynamic> resources,
  ) {
    if (resources['schema'] != 3) {
      throw const FormatException('EPUB 资源清单版本不受支持。');
    }
    final paths = <String>{text, manifest};
    for (final key in ['images', 'css', 'fonts']) {
      for (final row in resources[key] as List) {
        final path = (row as Map)['path'] as String;
        if (!p.isAbsolute(path) || !p.isWithin(generation, path)) {
          throw const FormatException('EPUB 缓存资源路径无效。');
        }
        paths.add(path);
      }
    }
    return paths.toList();
  }

  Future<EpubImportBundle?> _reuse(
    File receiptFile,
    File source,
    String sourceHash,
    bool Function() cancelled,
  ) async {
    try {
      if (!await receiptFile.exists()) return null;
      final receipt = jsonDecode(await receiptFile.readAsString()) as Map;
      if (receipt['version'] != 4 ||
          receipt['source_path'] != source.path ||
          receipt['source_sha256'] != sourceHash) {
        return null;
      }
      final name = receipt['generation'] as String;
      if (!RegExp(r'^g-[A-Za-z0-9_-]+$').hasMatch(name)) return null;
      final receiptName = p.basename(receiptFile.path);
      if (receiptName != 'current.json' && receiptName != 'ready-$name.json') {
        return null;
      }
      final generation = p.join(receiptFile.parent.path, name);
      final text = p.join(generation, 'book.txt');
      final manifest = p.join(generation, 'resources', 'manifest.json');
      final hashes = (receipt['files'] as Map).cast<String, String>();
      // Authenticate manifest before following its resource paths.
      if (await _hash(File(manifest), cancelled) !=
          hashes[p.relative(manifest, from: generation)]) {
        return null;
      }
      final resources = jsonDecode(
        await File(manifest).readAsString(),
      ) as Map<String, dynamic>;
      if (resources['source_path'] != source.path ||
          resources['resource_root'] != p.join(generation, 'resources')) {
        return null;
      }
      final paths = _paths(generation, text, manifest, resources);
      if (paths.length != hashes.length) return null;
      for (final path in paths) {
        if (await _hash(File(path), cancelled) !=
            hashes[p.relative(path, from: generation)]) {
          return null;
        }
      }
      if (await _hash(source, cancelled) != sourceHash) {
        throw const FormatException('读取期间原 EPUB 已改变，请重新导入。');
      }
      return EpubImportBundle(text, resources);
    } on FileSystemException {
      return null;
    } on TypeError {
      return null;
    } on FormatException {
      _check(cancelled);
      return null;
    }
  }
}
