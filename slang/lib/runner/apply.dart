import 'dart:io';

import 'package:collection/collection.dart';
import 'package:slang/builder/builder/translation_map_builder.dart';
import 'package:slang/builder/decoder/base_decoder.dart';
import 'package:slang/builder/model/enums.dart';
import 'package:slang/builder/model/i18n_locale.dart';
import 'package:slang/builder/model/raw_config.dart';
import 'package:slang/builder/utils/file_utils.dart';
import 'package:slang/builder/utils/path_utils.dart';
import 'package:slang/builder/utils/regex_utils.dart';
import 'package:slang/runner/analyze.dart';
import 'package:slang/runner/utils.dart';

const _supportedFiles = [FileType.json, FileType.yaml];

Future<void> runApplyTranslations({
  required SlangFileCollection fileCollection,
  required List<String> arguments,
}) async {
  final rawConfig = fileCollection.config;
  String? outDir;
  List<I18nLocale>? targetLocales; // only this locale will be considered
  for (final a in arguments) {
    if (a.startsWith('--outdir=')) {
      outDir = a.substring(9).toAbsolutePath();
    } else if (a.startsWith('--locale=')) {
      targetLocales = [I18nLocale.fromString(a.substring(9))];
    }
  }

  if (outDir == null) {
    outDir = rawConfig.inputDirectory;
    if (outDir == null) {
      throw 'input_directory or --outdir=<path> must be specified.';
    }
  }

  final translationMap = await TranslationMapBuilder.build(
    rawConfig: rawConfig,
    files: fileCollection.translationFiles,
    verbose: false,
  );

  print('Looking for missing translations files in $outDir');
  final files =
      Directory(outDir).listSync(recursive: true).whereType<File>().toList();
  final missingTranslationsMap = _readMissingTranslations(
    files: files,
    targetLocales: targetLocales,
  );

  if (targetLocales == null) {
    // If no locales are specified, then we only apply changed files
    // To know what has been changed, we need to regenerate the analysis
    print('');
    print('Regenerating analysis...');
    final analysis = getMissingTranslations(
      rawConfig: rawConfig,
      translations: translationMap.toI18nModel(rawConfig),
    );

    final ignoreBecauseMissing = <I18nLocale>[];
    final ignoreBecauseEqual = <I18nLocale>[];
    for (final entry in {...missingTranslationsMap}.entries) {
      final locale = entry.key;
      final existingMissing = {...entry.value};
      final analysisMissing = analysis[entry.key];

      if (analysisMissing == null) {
        ignoreBecauseMissing.add(locale);
        missingTranslationsMap.remove(locale);
        continue;
      }

      if (DeepCollectionEquality().equals(existingMissing, analysisMissing)) {
        ignoreBecauseEqual.add(locale);
        missingTranslationsMap.remove(locale);
        continue;
      }
    }

    if (ignoreBecauseMissing.isNotEmpty) {
      print(
          ' -> Ignoring because missing in new analysis: ${ignoreBecauseMissing.joinedAsString}');
    }
    if (ignoreBecauseEqual.isNotEmpty) {
      print(
          ' -> Ignoring because no changes: ${ignoreBecauseEqual.joinedAsString}');
    }
  }

  if (missingTranslationsMap.isEmpty) {
    print('');
    print('No changes');
    return;
  }

  print('');
  print(
      'Applying: ${missingTranslationsMap.keys.map((l) => '<${l.languageTag}>').join(' ')}');

  final translationFiles = fileCollection.files;

  // We need to read the base translations to determine
  // the order of the secondary translations
  final baseTranslationMap = translationMap[rawConfig.baseLocale]!;

  // The actual apply process:
  for (final entry in missingTranslationsMap.entries) {
    final locale = entry.key;
    final missingTranslations = entry.value;

    print(' -> Apply <${locale.languageTag}>');
    _applyTranslationsForOneLocale(
      rawConfig: rawConfig,
      applyLocale: locale,
      baseTranslations: baseTranslationMap,
      newTranslations: missingTranslations,
      candidateFiles: translationFiles,
    );
  }
}

/// Reads the missing translations.
/// If [targetLocales] is specified, then only these locales are read.
Map<I18nLocale, Map<String, dynamic>> _readMissingTranslations({
  required List<File> files,
  required List<I18nLocale>? targetLocales,
}) {
  final Map<I18nLocale, Map<String, dynamic>> resultMap = {};
  for (final file in files) {
    final fileName = PathUtils.getFileName(file.path);
    final fileNameMatch =
        RegexUtils.missingTranslationsFileRegex.firstMatch(fileName);
    if (fileNameMatch == null) {
      continue;
    }

    final locale = fileNameMatch.group(1) != null
        ? I18nLocale.fromString(fileNameMatch.group(1)!)
        : null;
    if (locale != null &&
        targetLocales != null &&
        !targetLocales.contains(locale)) {
      continue;
    }

    final fileType = _supportedFiles
        .firstWhereOrNull((type) => type.name == fileNameMatch.group(2)!);
    if (fileType == null) {
      throw FileTypeNotSupportedError(file);
    }
    final content = File(file.path).readAsStringSync();

    final Map<String, dynamic> parsedContent;
    try {
      parsedContent =
          BaseDecoder.getDecoderOfFileType(fileType).decode(content);
    } on FormatException catch (e) {
      print('');
      throw 'File: ${file.path}\n$e';
    }

    if (locale != null) {
      _printReading(locale, file);
      resultMap[locale] = {...parsedContent}..remove(INFO_KEY);
    } else {
      // handle file containing multiple locales
      for (final entry in parsedContent.entries) {
        if (entry.key.startsWith(INFO_KEY)) {
          continue;
        }

        final locale = I18nLocale.fromString(entry.key);

        if (targetLocales != null && !targetLocales.contains(locale)) {
          continue;
        }

        _printReading(locale, file);
        resultMap[locale] = entry.value;
      }
    }
  }

  return resultMap;
}

/// Apply translations only for ONE locale.
/// Scans existing translations files, loads its content, and finally adds translations.
/// Throws an error if the file could not be found.
///
/// [newTranslations] is a map of "Namespace -> Translations"
/// [candidateFiles] are files that are applied to; Only a subset may be used
void _applyTranslationsForOneLocale({
  required RawConfig rawConfig,
  required I18nLocale applyLocale,
  required Map<String, Map<String, dynamic>> baseTranslations,
  required Map<String, dynamic> newTranslations,
  required List<File> candidateFiles,
}) {
  final fileMap = <String, File>{}; // namespace -> file

  for (final file in candidateFiles) {
    final fileNameNoExtension = PathUtils.getFileNameNoExtension(file.path);
    final baseFileMatch =
        RegexUtils.baseFileRegex.firstMatch(fileNameNoExtension);

    if (baseFileMatch != null) {
      if (rawConfig.namespaces) {
        // a file without locale (but locale may be in directory name!)
        final directoryLocale = PathUtils.findDirectoryLocale(
          filePath: file.path,
          inputDirectory: rawConfig.inputDirectory,
        );
        if (directoryLocale == applyLocale ||
            rawConfig.baseLocale == applyLocale) {
          fileMap[fileNameNoExtension] = file;
        }
      }
    } else {
      // a file containing a locale
      final match =
          RegexUtils.fileWithLocaleRegex.firstMatch(fileNameNoExtension);

      if (match != null) {
        final namespace = match.group(1)!;
        final locale = I18nLocale(
          language: match.group(2)!,
          script: match.group(3),
          country: match.group(4),
        );

        if (locale == applyLocale) {
          fileMap[namespace] = file;
        }
      }
    }
  }

  if (fileMap.isEmpty) {
    throw 'Could not find a file for locale <${applyLocale.languageTag}>';
  }

  if (rawConfig.namespaces) {
    for (final entry in fileMap.entries) {
      if (!newTranslations.containsKey(entry.key)) {
        // This namespace exists but it is not specified in new translations
        continue;
      }
      _applyTranslationsForFile(
        baseTranslations: baseTranslations[entry.key] ?? {},
        newTranslations: newTranslations[entry.key],
        destinationFile: entry.value,
      );
    }
  } else {
    // only apply for the first namespace
    _applyTranslationsForFile(
      baseTranslations: baseTranslations.values.first,
      newTranslations: newTranslations,
      destinationFile: fileMap.values.first,
    );
  }
}

/// Reads the [destinationFile]. Applies [newTranslations] to it
/// while respecting the order of [baseTranslations].
///
/// In namespace mode, this function represents ONE namespace.
/// [baseTranslations] should also only contain the selected namespace.
///
/// If the key does not exist in [baseTranslations], then it will be appended
/// after known keys (i.e. at the end of the file).
void _applyTranslationsForFile({
  required Map<String, dynamic> baseTranslations,
  required Map<String, dynamic> newTranslations,
  required File destinationFile,
}) {
  final existingFile = destinationFile;
  final existingContent = existingFile.readAsStringSync();
  final fileType = _supportedFiles.firstWhereOrNull(
      (type) => type.name == PathUtils.getFileExtension(existingFile.path));
  if (fileType == null) {
    throw FileTypeNotSupportedError(existingFile);
  }
  final Map<String, dynamic> parsedContent;
  try {
    parsedContent =
        BaseDecoder.getDecoderOfFileType(fileType).decode(existingContent);
  } on FormatException catch (e) {
    print('');
    throw 'File: ${existingFile.path}\n$e';
  }

  final appliedTranslations = applyMapRecursive(
    baseMap: baseTranslations,
    newMap: newTranslations,
    oldMap: parsedContent,
  );

  FileUtils.writeFileOfType(
    fileType: fileType,
    path: existingFile.path,
    content: appliedTranslations,
  );
  _printApplyingDestination(existingFile);
}

/// Adds entries from [newMap] to [oldMap] while respecting the order specified
/// in [baseMap].
///
/// The returned map is a new instance (i.e. no side effects for the given maps)
Map<String, dynamic> applyMapRecursive({
  String? path,
  required Map<String, dynamic> baseMap,
  required Map<String, dynamic> newMap,
  required Map<String, dynamic> oldMap,
}) {
  final resultMap = <String, dynamic>{};
  for (final key in baseMap.keys) {
    dynamic actualValue = newMap[key] ?? oldMap[key];
    if (actualValue == null) {
      continue;
    }
    final currPath = path == null ? key : '$path.$key';

    if (actualValue is Map) {
      actualValue = applyMapRecursive(
        path: currPath,
        baseMap: baseMap[key] is Map
            ? baseMap[key]
            : throw 'In the base translations, "$key" is not a map.',
        newMap: newMap[key] ?? {},
        oldMap: oldMap[key] ?? {},
      );
    }

    if (newMap[key] != null) {
      _printAdding(currPath, actualValue);
    }
    resultMap[key] = actualValue;
  }

  // Add keys from old map that are unknown in base locale
  for (final key in oldMap.keys) {
    if (resultMap.containsKey(key)) {
      continue;
    }
    final currPath = path == null ? key : '$path.$key';

    dynamic actualValue = newMap[key] ?? oldMap[key];
    if (actualValue is Map) {
      actualValue = applyMapRecursive(
        path: currPath,
        baseMap: {},
        newMap: newMap[key] ?? {},
        oldMap: oldMap[key],
      );
    }

    if (newMap[key] != null) {
      _printAdding(currPath, actualValue);
    }
    resultMap[key] = actualValue;
  }

  // Add remaining new keys
  for (final key in newMap.keys) {
    if (resultMap.containsKey(key)) {
      continue;
    }
    final currPath = path == null ? key : '$path.$key';
    _printAdding(currPath, newMap[key]);
    resultMap[key] = newMap[key];
  }

  return resultMap;
}

class FileTypeNotSupportedError extends UnsupportedError {
  FileTypeNotSupportedError(File file)
      : super(
            'The file "${file.path}" has an invalid file extension (supported: ${_supportedFiles.map((e) => e.name)})');
}

void _printReading(I18nLocale locale, File file) {
  print(' -> Reading <${locale.languageTag}> from ${file.path}');
}

void _printApplyingDestination(File file) {
  print('    -> Update ${file.path}');
}

void _printAdding(String path, Object value) {
  if (value is Map) {
    return;
  }
  print('    -> Set [$path]: "$value"');
}

extension on List<I18nLocale> {
  String get joinedAsString {
    return map((l) => '<${l.languageTag}>').join(' ');
  }
}
