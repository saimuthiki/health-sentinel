import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/api/api_client.dart';
import '../../data/api/api_failure.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../../data/repository/health_repository.dart';
import '../reports/report_upload.dart';

// Getting a photograph out of the chat composer and up to the backend.
//
// Two things are happening in this file and it is worth separating them before
// you read it.
//
// The first is ordinary plumbing: choose a picture, check it, send it. That is
// the same shape as `features/reports/report_upload.dart` - the choosing is put
// behind ChatPhotoPicker, which the screen reaches through
// chatPhotoPickerProvider and a test swaps for something that hands back bytes,
// and everything else is plain Dart that runs in a test.
//
// The second is not plumbing at all, and it is the reason the API here has two
// kinds rather than one button. The owner asked for a camera so somebody can
// say "I ate this", and so somebody can photograph a skin problem. The app
// treats those two completely differently, and it is the *person* who says
// which it is, before the camera opens. Nothing here, and nothing on the
// server, tries to work it out from the picture. A photo sent as a meal is read
// as food; a photo sent as a skin or body concern is kept with the conversation
// and is never shown to the AI at all - the app says so plainly at the moment
// it is attached, and answers in words instead. `backend/app/rules/chat_photos.py`
// is where that decision lives and why it is written down at length.

/// Which of the two things this photograph is. The person's own answer.
enum ChatPhotoKind {
  /// A plate, a packet, a menu - something they ate or are about to.
  meal('meal', 'A meal or a food label', 'Photo of a meal'),

  /// A rash, a patch, a swelling. Kept, never read by the AI.
  body('body', 'A skin or body concern', 'Photo of a skin or body concern');

  const ChatPhotoKind(this.wire, this.choiceLabel, this.chipLabel);

  /// What the backend calls it. This is the last path segment of the upload, so
  /// there is no way to send a photo without having answered the question.
  final String wire;

  /// How the choice reads in the sheet.
  final String choiceLabel;

  /// How the attached photo reads above the composer, and in the conversation.
  /// Deliberately the same words `app/rules/chat_photos.py` uses, so a message
  /// reloaded from the server does not suddenly change its label.
  final String chipLabel;
}

/// Where the picture comes from. There is no third way in: a document picker
/// belongs on the Reports tab, which is built to read documents.
enum ChatPhotoSource { camera, gallery }

/// What a report attached to a message is called in the conversation.
///
/// The backend's word for it (`REPORT_LABEL` in `app/rules/chat_photos.py`),
/// repeated here so the local echo of a message and the same message reloaded
/// from the server are labelled identically.
const String reportChipLabel = 'Report';

/// The largest photo the backend will accept.
///
/// Taken from `report_upload.dart` rather than written again, which is also
/// where the byte-level type check comes from. Both mirror the backend
/// (`backend/app/core/config.py` and `backend/app/ingest/files.py`), and one
/// copy of a number that has to match is easier to keep true than two.
const int maxChatPhotoBytes = maxReportBytes;

/// Said when the bytes are not a photograph the backend can open.
///
/// Deliberately different from the reports wording: a PDF is a perfectly good
/// report and a perfectly bad chat photo, so the sentence has to send somebody
/// to the right place rather than just refuse them.
const String notAPhotoMessage =
    'That does not look like a photo. Chat takes JPEG, PNG or HEIC pictures — '
    'if it is a lab report or a PDF, add it on the Reports tab and it will be '
    'read properly.';

/// Said when the upload falls over and there is nothing better to say.
const String photoUploadFallbackMessage =
    'That photo could not be sent just now. Nothing has been lost — it is still '
    'on your phone, so you can try again.';

/// Said in a build that has no backend to send anything to.
const String photoNeedsBackendMessage =
    'Photos need a connection to the health engine. This copy of the app is '
    'showing sample data, so there is nothing to send one to.';

/// Why this photo cannot be sent, or null when it can be.
///
/// Runs before a byte goes out, so nobody waits through an upload on a phone
/// connection to be told at the end that it was never going to be accepted.
String? describeChatPhotoRefusal(Uint8List bytes) {
  if (bytes.isEmpty) {
    return 'That file was empty.';
  }
  if (bytes.length > maxChatPhotoBytes) {
    return describeFileTooLarge(bytes.length);
  }
  final String? mimeType = sniffReportMimeType(bytes);
  if (mimeType == null || !mimeType.startsWith('image/')) {
    // Covers a PDF, which sniffs perfectly well and is still not a photo.
    return notAPhotoMessage;
  }
  return null;
}

/// One chosen photograph, in memory, on its way up.
class PickedChatPhoto {
  PickedChatPhoto({
    required this.fileName,
    required this.bytes,
    required this.kind,
  }) : mimeType = sniffReportMimeType(bytes);

  final String fileName;
  final Uint8List bytes;

  /// What the person said this is. Fixed at the moment they chose, and carried
  /// all the way to the backend.
  final ChatPhotoKind kind;

  /// What the bytes say this is, or null when they say nothing we recognise.
  final String? mimeType;

  /// The id the backend gave this photo, once it has been uploaded.
  ///
  /// Held on the picked photo rather than somewhere else so that a send which
  /// failed *after* the upload can be retried without uploading the same
  /// picture a second time - and without leaving a second copy of it in
  /// storage every time somebody taps send on a bad connection.
  String? uploadedId;

  /// What the backend called it, once it has been uploaded.
  String? uploadedLabel;

  /// What to call this photo on screen.
  ///
  /// The server's word for it when there is one, because the server is what
  /// labels the same message when the conversation is reloaded. [kind] answers
  /// before the upload has landed, and the two agree.
  String get chipLabel => uploadedLabel ?? kind.chipLabel;
}

/// A problem worth telling the person about, already written for them.
///
/// A [HealthRepositoryException] rather than a type of its own, so that
/// `explainFailure` - the one place on any screen allowed to turn a thrown
/// object into words - handles it exactly as it handles everything else.
class ChatPhotoException extends HealthRepositoryException {
  const ChatPhotoException(super.message);
}

/// Choosing a picture. The one part of this that needs the actual phone.
///
/// Returning null means the person backed out of the picker, which is the
/// commonest outcome by a distance and is not a failure of any kind.
abstract class ChatPhotoPicker {
  Future<PickedChatPhoto?> pick(ChatPhotoKind kind, ChatPhotoSource source);
}

/// The picker the app runs on a real phone. Overridden in tests, where there is
/// no camera, no gallery and no platform to answer a method channel.
final chatPhotoPickerProvider = Provider<ChatPhotoPicker>((ref) {
  return const PlatformChatPhotoPicker();
});

/// `image_picker`, for the camera and the gallery.
class PlatformChatPhotoPicker implements ChatPhotoPicker {
  const PlatformChatPhotoPicker();

  @override
  Future<PickedChatPhoto?> pick(
    ChatPhotoKind kind,
    ChatPhotoSource source,
  ) async {
    final ImageSource from = source == ChatPhotoSource.camera
        ? ImageSource.camera
        : ImageSource.gallery;
    XFile? file;
    try {
      file = await ImagePicker().pickImage(
        source: from,
        // No maxWidth, maxHeight or imageQuality, for the same reason as the
        // report picker: re-encoding loses detail, and detail is the whole
        // content of the picture.
        //
        // requestFullMetadata is off because we have no use for the photo's
        // metadata and every reason not to carry it. A picture of somebody's
        // arm taken at home has the home's coordinates written into it.
        requestFullMetadata: false,
      );
    } on PlatformException catch (error) {
      throw ChatPhotoException(_failureMessage(error, source));
    }

    if (file == null) {
      return null;
    }
    return PickedChatPhoto(
      fileName: _fileName(file, source),
      bytes: await file.readAsBytes(),
      kind: kind,
    );
  }

  /// A name worth showing. A gallery photo keeps its own; one just taken has a
  /// random temporary name, so it gets a written one.
  static String _fileName(XFile file, ChatPhotoSource source) {
    final String name = file.name;
    if (source == ChatPhotoSource.gallery && name.isNotEmpty) {
      return name;
    }
    final int dot = name.lastIndexOf('.');
    final String extension = dot > 0 ? name.substring(dot) : '.jpg';
    return 'Chat photo$extension';
  }

  /// A camera or gallery refusal, said as what happened and what fixes it.
  static String _failureMessage(
    PlatformException error,
    ChatPhotoSource source,
  ) {
    switch (error.code) {
      case 'camera_access_denied':
        return 'HealthPulse does not have permission to use the camera. You can '
            'switch it on in your phone’s Settings, under Apps, then '
            'HealthPulse, then Permissions — or take the picture with your '
            'usual camera app and pick it from your gallery instead.';
      case 'photo_access_denied':
        return 'HealthPulse does not have permission to open your photos. You '
            'can switch photos on in your phone’s Settings, under Apps, then '
            'HealthPulse, then Permissions — or use “Take a photo” instead.';
      case 'no_available_camera':
        return 'This phone does not have a camera app we can open. Picking a '
            'photo from your gallery will still work.';
      case 'already_active':
        return 'A photo is already being chosen. Finish that first, then try '
            'again.';
    }
    return source == ChatPhotoSource.camera
        ? 'The camera could not be opened just now. Please try again, or pick a '
            'photo from your gallery instead.'
        : 'Your photos could not be opened just now. Please try again.';
  }
}

/// What came back from storing one photograph.
class ChatPhotoUpload {
  const ChatPhotoUpload({
    required this.photoId,
    required this.label,
    required this.notices,
  });

  /// The id a message can carry. Opaque to this app.
  final String photoId;

  /// What the conversation should call it, in the backend's words.
  final String label;

  /// Anything the person is owed about this photo straight away — for a skin
  /// photo, that it will be kept and not interpreted.
  ///
  /// Read from the response rather than written here, on purpose. There is one
  /// author of that sentence, `backend/app/rules/chat_photos.py`, and a second
  /// copy on the phone would be a second copy to keep true.
  final List<String> notices;
}

/// What came back from a message that carried a photo.
class ChatPhotoReply {
  const ChatPhotoReply({required this.threadId, required this.notes});

  /// The conversation the message landed in, or null when the server did not
  /// name one.
  final String? threadId;

  /// What the backend did, or refused to do, with the photo — in the backend's
  /// own curated words, never the AI's. Empty for an ordinary meal photo.
  ///
  /// The reply itself is deliberately not carried here: it arrives in the
  /// conversation when the screen reloads it, the same way every other reply
  /// does, so there is one path by which an answer reaches the bubbles.
  final List<String> notes;
}

/// Sending a photograph, and then the message that carries it.
///
/// A feature-local service rather than a method on the repository, for the same
/// reason `report_upload.dart` keeps its picker local: this is the only screen
/// that does it, and the two calls it makes are specific to it.
///
/// **Why two calls and not one.** The photo goes up the moment it is attached
/// and comes back as an id; the message is posted with that id when send is
/// tapped. Three things fall out of that, all of them wanted: the message stays
/// a small JSON body like every other message; the wait for a big picture on a
/// phone connection happens while somebody is still typing rather than after
/// they have pressed send; and the sentence about a skin photo not being
/// interpreted arrives from the server, and is shown, *before* the message goes
/// anywhere. A send that fails is retried without uploading the picture again,
/// because the id is kept on [PickedChatPhoto.uploadedId].
abstract class ChatPhotoService {
  /// Store the photo and return the id a message can carry.
  Future<ChatPhotoUpload> upload(
    PickedChatPhoto photo, {
    void Function(int sent, int total)? onProgress,
  });

  /// Post the message with the photo ids attached.
  Future<ChatPhotoReply> send({
    required String message,
    required List<String> photoIds,
    required List<String> reportIds,
  });
}

/// The service, or null in a build with no backend address.
///
/// Null rather than a stub that throws on use, so the screen can say the honest
/// thing — [photoNeedsBackendMessage] — before opening a camera it has nowhere
/// to send the result of.
final chatPhotoServiceProvider = Provider<ChatPhotoService?>((ref) {
  final ApiClient? api = ref.watch(apiClientProvider);
  if (api == null) {
    return null;
  }
  return HttpChatPhotoService(api);
});

/// The real one, against our own FastAPI service.
class HttpChatPhotoService implements ChatPhotoService {
  HttpChatPhotoService(this._api);

  final ApiClient _api;

  /// The conversation this app is showing, remembered between calls.
  String? _threadId;

  @override
  Future<ChatPhotoUpload> upload(
    PickedChatPhoto photo, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final String? refusal = describeChatPhotoRefusal(photo.bytes);
    if (refusal != null) {
      throw ChatPhotoException(refusal);
    }
    final String? mimeType = photo.mimeType;
    if (mimeType == null) {
      throw const ChatPhotoException(notAPhotoMessage);
    }
    try {
      // The kind is the last part of the address, which is what makes it
      // impossible to upload a photo without having said which sort it is.
      final Map<String, dynamic> json = await _api.uploadFile(
        '/v1/chat/photos/${photo.kind.wire}',
        field: 'file',
        filename: photo.fileName,
        contentType: mimeType,
        bytes: photo.bytes,
        onProgress: onProgress,
      );
      final String id = asString(json['photo_id']);
      if (id.isEmpty) {
        throw const ChatPhotoException(photoUploadFallbackMessage);
      }
      return ChatPhotoUpload(
        photoId: id,
        label: asString(json['label'], fallback: photo.kind.chipLabel),
        notices: asStringList(json['notices']),
      );
    } on ApiFailure catch (failure) {
      throw ChatPhotoException(failure.message);
    }
  }

  @override
  Future<ChatPhotoReply> send({
    required String message,
    required List<String> photoIds,
    required List<String> reportIds,
  }) async {
    try {
      final String? threadId = await _currentThreadId();
      final Map<String, dynamic> json = await _api.postMap(
        '/v1/chat/messages',
        body: <String, dynamic>{
          'message': message,
          if (threadId != null) 'thread_id': threadId,
          'attachment_report_ids': reportIds.take(5).toList(),
          'photo_ids': photoIds.take(3).toList(),
        },
      );
      final String replyThread = asString(json['thread_id']);
      _threadId = replyThread.isEmpty ? _threadId : replyThread;
      return ChatPhotoReply(
        threadId: _threadId,
        notes: asStringList(json['photo_notes']),
      );
    } on ApiFailure catch (failure) {
      throw ChatPhotoException(failure.message);
    }
  }

  /// Which conversation to post into.
  ///
  /// The repository keeps its own copy of this and does not expose it, so this
  /// asks the backend the same question the repository asks when it loads the
  /// messages: the newest thread is the one on screen. Getting this wrong would
  /// be quietly awful — the message would land in a brand-new conversation and
  /// the screen would look like it had forgotten everything.
  ///
  /// A failure here is swallowed on purpose. Not knowing the thread is not a
  /// reason to refuse to send: the backend opens one when it is not told which,
  /// and a message in a new thread is better than a message nowhere.
  Future<String?> _currentThreadId() async {
    if (_threadId != null) {
      return _threadId;
    }
    try {
      final List<dynamic> threads = await _api.getList('/v1/chat/threads');
      for (final dynamic row in threads) {
        if (row is Map) {
          final String id = asString(row.cast<String, dynamic>()['id']);
          if (id.isNotEmpty) {
            _threadId = id;
            return id;
          }
        }
      }
    } on ApiFailure {
      return null;
    }
    return null;
  }
}
