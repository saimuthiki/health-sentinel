import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

// Getting one report file off this phone and into the app, safely.
//
// This file is deliberately separate from the screen. Choosing a file is the
// only part of uploading that needs the phone itself - a camera, a gallery, a
// file browser - and none of that exists in a widget test. So the choosing is
// put behind ReportPicker, which the screen asks for through
// reportPickerProvider and a test can swap for something that just hands back a
// file. Everything else in here - the size limit, the type check, the wording
// of a refusal - is ordinary Dart that runs anywhere, so it can be tested
// properly rather than trusted.

/// Which of the three ways in the "Add a report" sheet was tapped.
enum ReportSource {
  /// A file already on the phone or in a cloud drive, usually the lab's PDF.
  pdf,

  /// A photo taken there and then of a printed report.
  camera,

  /// A photo of a report that is already in the gallery.
  gallery,
}

/// The largest file the backend will accept, in bytes.
///
/// This is `max_upload_bytes` from `backend/app/core/config.py`, copied here on
/// purpose rather than fetched. The whole point of knowing it on the phone is to
/// turn a file down *before* it is sent, and asking the backend how big a file
/// may be would mean waiting on a server that is very likely asleep.
const int maxReportBytes = 20 * 1024 * 1024;

/// Said when the bytes are not a kind of file the backend can open.
///
/// Word for word what `backend/app/ingest/files.py` would have answered, so
/// somebody who hits this on a bad connection - and so gets the refusal from the
/// server instead of from here - is not told two different things.
const String unreadableFileMessage =
    'We could not tell what kind of file that is. Please upload a PDF, or a '
    'JPEG, PNG or HEIC photo.';

/// Said when the upload itself falls over and we have nothing better to say.
const String uploadFallbackMessage =
    'Your report could not be sent just now. Nothing has been lost - the file '
    'is still on your phone, so you can try again.';

/// The ISO container brands that mean a HEIC or HEIF photo.
const Set<String> _heifBrands = <String>{
  'heic',
  'heix',
  'hevc',
  'hevx',
  'mif1',
  'msf1',
  'heim',
  'heis',
  'hevm',
  'hevs',
};

/// What the first bytes of the file say it is, or null if we do not recognise it.
///
/// The type is read out of the file itself, never out of its name and never out
/// of which of the three buttons was tapped. A file called `report.pdf` that is
/// really a photo is still a photo, and the extension is the one part of a file
/// that anybody can change. This is the same test the backend runs in
/// `backend/app/ingest/files.py`, so the answer the app sends up as the content
/// type is the answer the backend is about to work out for itself.
String? sniffReportMimeType(Uint8List bytes) {
  // Fewer than 32 bytes is not a report of any kind, and is not enough to read
  // a container header out of either.
  if (bytes.length < 32) {
    return null;
  }
  if (_startsWith(bytes, const <int>[0x25, 0x50, 0x44, 0x46, 0x2D])) {
    return 'application/pdf'; // "%PDF-"
  }
  if (_startsWith(bytes, const <int>[0xFF, 0xD8, 0xFF])) {
    return 'image/jpeg';
  }
  if (_startsWith(
    bytes,
    const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
  )) {
    return 'image/png';
  }
  // HEIC, which is what a modern iPhone and many Android cameras save: an ISO
  // box named "ftyp" at offset 4, then a four-letter brand saying what is in it.
  final String box = String.fromCharCodes(bytes.getRange(4, 8));
  final String brand = String.fromCharCodes(bytes.getRange(8, 12));
  if (box == 'ftyp' && _heifBrands.contains(brand)) {
    return 'image/heic';
  }
  return null;
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) {
    return false;
  }
  for (int i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}

/// Why this file cannot be sent, or null when it can be.
///
/// Called before a single byte goes out. Both sentences are the backend's own,
/// because the alternative is somebody waiting through a long upload on a phone
/// connection only to be told at the end that the file was never going to be
/// accepted.
String? describeUploadRefusal(Uint8List bytes) {
  if (bytes.isEmpty) {
    return 'That file was empty.';
  }
  if (bytes.length > maxReportBytes) {
    return describeFileTooLarge(bytes.length);
  }
  if (sniffReportMimeType(bytes) == null) {
    return unreadableFileMessage;
  }
  return null;
}

/// The "too big" sentence, with the same arithmetic the backend uses.
///
/// Megabytes here are millions of bytes, which is how a phone reports the size
/// of a photo, rather than the 1024-based megabytes the limit is written in.
/// That is the backend's choice and it is copied rather than corrected: two
/// different numbers for one limit would be worse than one slightly generous one.
String describeFileTooLarge(int sizeInBytes) {
  final String size = (sizeInBytes / 1000000).toStringAsFixed(1);
  final String limit = (maxReportBytes / 1000000).toStringAsFixed(0);
  return 'That file is $size MB. The limit is $limit MB. A photo of each page '
      'usually fits.';
}

/// One chosen file, in memory, on its way to the backend.
class PickedReport {
  PickedReport({required this.fileName, required this.bytes})
      : mimeType = sniffReportMimeType(bytes);

  /// What to call it. Shown in the reports list until the lab's own name is
  /// extracted from the page.
  final String fileName;

  final Uint8List bytes;

  /// What the bytes say this is, or null when they say nothing we recognise.
  final String? mimeType;
}

/// A problem worth telling the person about, already written for them.
///
/// Never carries a platform error code or an exception's `toString()`: those are
/// written for whoever wrote the code, not for whoever is holding the phone.
class ReportPickerException implements Exception {
  const ReportPickerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Choosing a file. The one part of uploading that needs the actual phone.
///
/// Returning null means the person backed out of the picker, which is the
/// commonest outcome by a distance and is not a failure of any kind.
abstract class ReportPicker {
  Future<PickedReport?> pick(ReportSource source);
}

/// The picker the app runs on a real phone.
///
/// Overridden in tests, where there is no camera, no gallery and no platform to
/// answer a method channel.
final reportPickerProvider = Provider<ReportPicker>((ref) {
  return const PlatformReportPicker();
});

/// `file_picker` for documents, `image_picker` for the two photo routes.
class PlatformReportPicker implements ReportPicker {
  const PlatformReportPicker();

  @override
  Future<PickedReport?> pick(ReportSource source) {
    switch (source) {
      case ReportSource.pdf:
        return _pickDocument();
      case ReportSource.camera:
        return _pickPhoto(ImageSource.camera);
      case ReportSource.gallery:
        return _pickPhoto(ImageSource.gallery);
    }
  }

  Future<PickedReport?> _pickDocument() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        // The filter is a courtesy, not a guarantee: it decides what the file
        // browser greys out, and any extension the phone does not recognise is
        // quietly dropped from it. The bytes are checked afterwards regardless.
        type: FileType.custom,
        allowedExtensions: const <String>[
          'pdf',
          'jpg',
          'jpeg',
          'png',
          'heic',
          'heif',
        ],
        allowMultiple: false,
        // Ask for the path rather than the bytes. The plugin copies the chosen
        // file into the app's cache either way, so a path always comes back on
        // Android, and reading it ourselves means a two-gigabyte video can be
        // turned down from its size alone instead of being loaded into memory
        // first and crashing the app on the way.
        withData: false,
      );
    } on PlatformException catch (error) {
      throw ReportPickerException(_documentFailureMessage(error));
    }

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final PlatformFile file = result.files.first;
    if (file.size > maxReportBytes) {
      throw ReportPickerException(describeFileTooLarge(file.size));
    }

    final Uint8List? alreadyRead = file.bytes;
    if (alreadyRead != null) {
      return PickedReport(fileName: file.name, bytes: alreadyRead);
    }
    final String? path = file.path;
    if (path == null) {
      throw const ReportPickerException(
        'That file could not be opened. Please try again, or choose a '
        'different one.',
      );
    }
    return PickedReport(
      fileName: file.name,
      bytes: await File(path).readAsBytes(),
    );
  }

  Future<PickedReport?> _pickPhoto(ImageSource source) async {
    XFile? file;
    try {
      file = await ImagePicker().pickImage(
        source: source,
        // No maxWidth, maxHeight or imageQuality on purpose. Setting any of the
        // three makes the plugin re-encode the picture, and the print on a lab
        // report is small enough that re-encoding is the difference between a
        // value being read and a value being guessed.
        //
        // requestFullMetadata is off because we have no use for the photo's
        // metadata and every reason not to carry it: a picture taken at home
        // has the home's coordinates in it, and this is a health upload.
        requestFullMetadata: false,
      );
    } on PlatformException catch (error) {
      throw ReportPickerException(_photoFailureMessage(error, source));
    }

    if (file == null) {
      return null;
    }
    final Uint8List bytes = await file.readAsBytes();
    return PickedReport(
      fileName: _photoFileName(file, source),
      bytes: bytes,
    );
  }

  /// A name a person will recognise in the reports list.
  ///
  /// A photo from the gallery keeps the name it already had. A photo just taken
  /// has no name - the plugin writes it to a temporary file with a random one -
  /// so it gets a written one, keeping the extension the plugin produced,
  /// because a list of thirty-two hexadecimal characters tells nobody anything.
  static String _photoFileName(XFile file, ImageSource source) {
    final String name = file.name;
    if (source == ImageSource.gallery && name.isNotEmpty) {
      return name;
    }
    final int dot = name.lastIndexOf('.');
    final String extension = dot > 0 ? name.substring(dot) : '.jpg';
    final DateTime now = DateTime.now();
    final String stamp = '${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}${_two(now.minute)}';
    return 'Report photo $stamp$extension';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _documentFailureMessage(PlatformException error) {
    if (error.code == 'already_active') {
      return 'A file is already being chosen. Finish that first, then try '
          'again.';
    }
    return 'That file could not be opened. Please try again, or choose a '
        'different one.';
  }

  /// A camera or gallery refusal, said as what happened and what fixes it.
  ///
  /// Android cannot tell us whether permission was refused once or refused for
  /// good, so the wording covers both: it names the switch either way, and it
  /// always offers the other route into the app, because somebody who will not
  /// give us the camera can still send us a PDF.
  static String _photoFailureMessage(
    PlatformException error,
    ImageSource source,
  ) {
    switch (error.code) {
      case 'camera_access_denied':
        return 'HealthPulse does not have permission to use the camera, so it '
            'could not be opened. You can switch the camera on in your phone’s '
            'Settings, under Apps, then HealthPulse, then Permissions - or take '
            'the picture with your usual camera app and pick it from your '
            'gallery instead.';
      case 'photo_access_denied':
        return 'HealthPulse does not have permission to open your photos. You '
            'can switch photos on in your phone’s Settings, under Apps, then '
            'HealthPulse, then Permissions - or use “Take a photo” instead.';
      case 'no_available_camera':
        return 'This phone does not have a camera app we can open. Choosing a '
            'PDF, or picking a photo from your gallery, will still work.';
      case 'already_active':
        return 'A photo is already being chosen. Finish that first, then try '
            'again.';
    }
    return source == ImageSource.camera
        ? 'The camera could not be opened just now. Please try again, or pick a '
            'photo from your gallery instead.'
        : 'Your photos could not be opened just now. Please try again.';
  }
}
