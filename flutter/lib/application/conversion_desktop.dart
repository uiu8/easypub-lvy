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
