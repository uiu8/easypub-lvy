import 'dart:io';
import 'dart:typed_data';

/// 成品文件的大小与修改时间（TASK-025）：每个文件只读一次磁盘并缓存，读不到就不显示。
FileStat? probeOutputStat(String path, Map<String, FileStat?> cache) =>
    cache.putIfAbsent(path, () {
      try {
        final stat = File(path).statSync();
        return stat.type == FileSystemEntityType.notFound ? null : stat;
      } catch (_) {
        return null;
      }
    });

/// 统一读取本机图片/资源字节（P0-02），避免页面层直接操作 dart:io File。
Future<Uint8List> readLocalFileBytes(String path) => File(path).readAsBytes();

abstract class BookSourceDesktop {
  Future<void> revealSource(String path);
}

abstract class ConversionDesktop {
  Future<String?> bundledConverter();
  Future<String?> chooseConverter();
  Future<void> openDirectory(String path);
  Future<void> openOutput(String path);
}

/// Optional desktop capability for opening licenses shipped beside the app.
abstract class OutputDirectoryDesktop {
  Future<String> defaultOutputDirectory();
}

abstract class LicenseDesktop {
  Future<String?> licenseDirectory(String category);
}

/// Optional capability for the independent KFX engine.
abstract interface class KfxConversionDesktop {
  Future<String?> bundledKfxConverter();
}

/// Local path validation shared by bundled and user-selected converters.
abstract interface class ConverterFileDesktop {
  Future<bool> converterExists(String path);
}
