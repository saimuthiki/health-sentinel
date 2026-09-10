import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Getting the finished export off this phone and somewhere the owner can find
// it.
//
// This file is separate from the screen for the same reason `report_upload.dart`
// is separate from the reports screen: handing a file to Android is the one part
// of exporting that needs an actual phone, and none of it exists in a widget
// test. So it sits behind [ExportSaver], which the screen asks for through
// [exportSaverProvider] and a test can swap for something that simply records
// what it was given.

/// What was saved, in the only terms we can honestly report.
///
/// Only the file **name** is kept. The Android save box hands the app a
/// document to write into rather than a folder path, and the plugin's own
/// answer assumes Downloads whatever the person actually chose — so the folder
/// is the one thing we genuinely do not know. The name is real: it is read back
/// off the document that was created, which is why a second export of the same
/// day can come back as `healthpulse-export-2026-09-10(1).json`.
class SavedExport {
  const SavedExport({required this.fileName});

  final String fileName;
}

/// A problem worth telling the person about, already written for them.
///
/// Never carries a platform error code or an exception's `toString()`: those
/// are written for whoever wrote the code, not for whoever is holding the phone.
class ExportSaverException implements Exception {
  const ExportSaverException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Writing the export to a file the person chooses.
///
/// Returning null means the save box was closed without choosing anywhere,
/// which is not a failure of any kind.
abstract class ExportSaver {
  Future<SavedExport?> save({
    required String fileName,
    required Uint8List bytes,
  });
}

/// The saver the app uses on a real phone. Overridden in tests.
final exportSaverProvider = Provider<ExportSaver>((ref) {
  return const PlatformExportSaver();
});

/// Android's own "save a document" box, through `file_picker`.
///
/// This is the whole reason the export can be delivered without adding a
/// package to the project. `FilePicker.platform.saveFile` with `bytes` opens the
/// system create-document dialog, lets the person pick the folder themselves —
/// Downloads, Documents, a Drive folder — and writes the bytes into whatever
/// they chose. The file lands somewhere they chose and can open, which is the
/// requirement: a complete health record must never be written somewhere the
/// person who owns it cannot find.
class PlatformExportSaver implements ExportSaver {
  const PlatformExportSaver();

  @override
  Future<SavedExport?> save({
    required String fileName,
    required Uint8List bytes,
  }) async {
    String? path;
    try {
      path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save your HealthPulse export',
        fileName: fileName,
        bytes: bytes,
      );
    } on PlatformException catch (error) {
      throw ExportSaverException(_failureMessage(error));
    }
    if (path == null) {
      // The save box was closed. Nothing was written and nothing is wrong.
      return null;
    }
    return SavedExport(fileName: _fileNameOf(path, fallback: fileName));
  }

  /// The last segment of whatever the plugin answered with.
  ///
  /// The path around it is not used anywhere on screen. See [SavedExport] for
  /// why: the plugin builds that path by assuming the Downloads folder, and
  /// telling somebody their health record is in a folder it may not be in is
  /// worse than telling them the name and letting their file browser find it.
  static String _fileNameOf(String path, {required String fallback}) {
    final int slash = path.lastIndexOf('/');
    final String name = slash == -1 ? path : path.substring(slash + 1);
    return name.trim().isEmpty ? fallback : name.trim();
  }

  static String _failureMessage(PlatformException error) {
    if (error.code == 'already_active') {
      return 'A file is already being chosen. Finish that first, then try '
          'again.';
    }
    return 'That file could not be saved. Try again and pick a folder you can '
        'write to, such as Downloads.';
  }
}
