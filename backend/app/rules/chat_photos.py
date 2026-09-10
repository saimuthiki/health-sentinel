"""Photos sent in chat: what kind they are, where they live, and what we refuse.

**No language model is involved anywhere in this file**, for the same reason as
:mod:`app.rules.symptom_flags`: the decision this module makes is the one that must not be
guessable, jailbreakable or different on a second run.

The product problem, in the owner's words, is two different photographs arriving through
one button: *"hey, I ate this and these items"*, and *"if there are any skin allergies, he
can take a photo"*. Those two need opposite handling, and getting it wrong in the direction
of "this is food" on a picture of a rash is the failure this module is built to prevent.

Three rules decide everything here.

**1. The kind is declared, never inferred.** The app asks which of the two it is and the
answer travels in the upload's URL. There is no "unknown" value and nothing defaults, so no
model is ever asked "what am I looking at?" as a routing question. A picture the user calls
food is handled as food; a picture they call a skin or body change is handled as one.

**2. A body photo never reaches a model.** Not with a careful prompt, not with a narrow
schema, not "just to describe it neutrally". The deterministic validator in
:mod:`app.safety.validator` reads *text*: it can catch a drug name or "you have eczema" in
a sentence, and it does. It cannot read an image, and it cannot catch the real failure
here, which is a fluent, correctly-spelled, drug-free sentence that talks somebody out of
going to a doctor -- *"it looks mild, keep it moisturised"*. The only control that is
structural rather than probabilistic is not sending the picture. So we accept it, store it,
say plainly that we do not interpret it, and hand the conversation to the ordinary symptom
path, where :mod:`app.rules.symptom_flags` has already read what the person typed.

That is also the honest answer rather than merely the cautious one. A dated photograph the
user can show a doctor, and compare with next week's, is worth more than a guess from an
app that is not allowed to examine anybody.

**3. A food photo may reach the model, and the model may only withhold.** The picture goes
up under a narrow instruction and a schema whose only extra field is ``photo_shows_food``.
When that comes back false -- the commonest way for it to be false is exactly the case
above, somebody photographing a rash and tapping the food button -- the model's own prose
is thrown away and :data:`NOT_FOOD_REPLY` is sent instead. A model signal is allowed to
*stop* an answer; it is never allowed to unlock one.

**Sourcing.** The "when to see somebody sooner" lines below are deliberately confined to
what is uncontroversial and non-specific: spreading, broken skin, fever, severe pain, and
the airway signs of a serious allergic reaction. They are written by the HealthPulse team
and are pending clinician review, in the same way as the phrase list in
:mod:`app.rules.symptom_flags` (see ``db/seed/GAPS.md`` item G7). Nothing here names a
condition, a medicine or a dose.
"""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass
from enum import StrEnum

from app.ingest.files import EXTENSIONS, HEIC, HEIF, JPEG, PNG

__all__ = [
    "BODY_PHOTO_CONTEXT_LINE",
    "BODY_PHOTO_NOTICE",
    "CHAT_PHOTO_MIME",
    "MEAL_PHOTO_CONTEXT_LINE",
    "NOT_FOOD_NOTICE",
    "NOT_FOOD_REPLY",
    "PHOTO_ID_RE",
    "REPORT_LABEL",
    "ChatPhoto",
    "ChatPhotoKind",
    "attachment_record",
    "label_for",
    "label_for_attachment",
    "new_photo_id",
    "parse_photo_id",
]


class ChatPhotoKind(StrEnum):
    """What the person said they were photographing. Their word, not our guess."""

    #: A meal, a plate, a packet, a menu -- something they ate or are about to.
    MEAL = "meal"

    #: A skin or body change. Accepted and stored; never sent to a model.
    BODY = "body"


#: The image types a chat photo may be. Deliberately **not** PDF: a PDF is a document, and
#: a document belongs on the Reports tab where it is read properly.
CHAT_PHOTO_MIME: tuple[str, ...] = (JPEG, PNG, HEIC, HEIF)

#: File extensions the ids above may end in, from :data:`app.ingest.files.EXTENSIONS`, so
#: the two lists cannot drift apart.
_EXTENSIONS: tuple[str, ...] = tuple(sorted({EXTENSIONS[mime] for mime in CHAT_PHOTO_MIME}))

#: Extension -> MIME, so the type sent to Gemini is derived from our own id rather than
#: from anything a client claims on the second request.
_MIME_FOR_EXTENSION: dict[str, str] = {EXTENSIONS[mime]: mime for mime in CHAT_PHOTO_MIME}

#: A photo id **is** the object's name inside the user's own storage folder, which is what
#: lets a photo exist with no table of its own and therefore with no migration.
#:
#: Two properties are load-bearing:
#:
#: * **The kind is part of the stored object's name.** Editing ``-body`` to ``-meal`` on the
#:   second request does not re-label the picture: it names a file that was never written,
#:   and the download fails. A photograph uploaded as a skin concern therefore cannot be
#:   pushed through the food path by a modified client -- the binding is the file store's,
#:   not a flag we chose to trust.
#: * The pattern admits nothing but 32 hex digits, one of two words and one of four
#:   extensions, so an id concatenated onto the user's folder cannot escape it. There is no
#:   ``/``, no ``.``-pair and no percent-encoding that survives this.
#: ``\Z`` rather than ``$``: in Python ``$`` also matches just before a trailing newline,
#: so ``<hex>-meal.jpg\n`` would satisfy a ``$``-anchored pattern. Nothing bad followed from
#: that here, because the parsed id is taken from the match rather than from the input --
#: but a validator that accepts a string it did not mean to accept is a validator waiting
#: for its second use to be the unlucky one.
PHOTO_ID_RE = re.compile(
    rf"\A(?P<stem>[0-9a-f]{{32}})-(?P<kind>{'|'.join(k.value for k in ChatPhotoKind)})"
    rf"\.(?P<ext>{'|'.join(_EXTENSIONS)})\Z"
)


@dataclass(frozen=True)
class ChatPhoto:
    """One stored chat photo, named by an id we minted and can re-read."""

    photo_id: str
    kind: ChatPhotoKind
    mime_type: str

    def storage_path(self, user_id: str) -> str:
        """``<user id>/<photo id>`` -- the convention ``db/policies/101_storage.sql``
        enforces, and, just as importantly, **flat**.

        The deletion sweep in :mod:`app.repositories.privacy` lists one storage prefix and
        removes what it finds. Supabase's list is not recursive, so a photo tucked into
        ``<user id>/chat/...`` would survive "delete all my health data" -- a broken promise
        that nobody would notice until it mattered. One folder deep is what is swept, so
        one folder deep is where these go, beside the report files.
        """
        return f"{user_id}/{self.photo_id}"


def new_photo_id(kind: ChatPhotoKind, mime_type: str) -> str:
    """Mint an id for a freshly uploaded photo of ``kind``.

    Random rather than content-hashed on purpose: two photographs of the same rash a week
    apart are the whole point of taking them, and a hash would silently collapse them into
    one. Report files dedupe by hash because re-reading a lab PDF costs a model call and
    yields the same numbers; nothing here is re-read.
    """
    extension = EXTENSIONS.get(mime_type)
    if extension not in _MIME_FOR_EXTENSION:
        raise ValueError(f"{mime_type} is not an image a chat photo may be")
    return f"{uuid.uuid4().hex}-{kind.value}.{extension}"


def parse_photo_id(photo_id: str) -> ChatPhoto | None:
    """``photo_id`` as a :class:`ChatPhoto`, or None when it is not one of ours."""
    match = PHOTO_ID_RE.match(photo_id or "")
    if match is None:
        return None
    return ChatPhoto(
        photo_id=match.group(0),
        kind=ChatPhotoKind(match.group("kind")),
        mime_type=_MIME_FOR_EXTENSION[match.group("ext")],
    )


#: What a photo is called in the conversation. Our own words, from this table, never a
#: file name off somebody's phone and never anything a model wrote.
_LABELS: dict[ChatPhotoKind, str] = {
    ChatPhotoKind.MEAL: "Photo of a meal",
    ChatPhotoKind.BODY: "Photo of a skin or body concern",
}

#: The label for a report attached by id, so one function answers for both kinds of
#: attachment the conversation can show.
REPORT_LABEL = "Report"


def label_for(kind: ChatPhotoKind) -> str:
    return _LABELS[kind]


def attachment_record(photo: ChatPhoto, user_id: str) -> dict[str, str]:
    """The row written into ``chat_messages.attachments``.

    An existing ``jsonb`` column, which is why this feature needs no migration. It carries
    the storage path so that an export or a later sweep can see the file exists without
    having to guess at a naming convention.
    """
    return {
        "type": "chat_photo",
        "kind": photo.kind.value,
        "photo_id": photo.photo_id,
        "storage_path": photo.storage_path(user_id),
    }


def label_for_attachment(record: object) -> str | None:
    """The display label for one stored attachment record, or None if we cannot name it."""
    if not isinstance(record, dict):
        return None
    kind = str(record.get("type") or "")
    if kind == "report":
        return REPORT_LABEL
    if kind == "chat_photo":
        try:
            return label_for(ChatPhotoKind(str(record.get("kind"))))
        except ValueError:
            return None
    return None


# ------------------------------------------------------------------------ curated copy

#: Said when a skin or body photo is attached -- once at upload, and again on the reply, so
#: it is on screen before the person waits for an answer and still there afterwards.
#:
#: Every sentence is checked against :func:`app.safety.validator.validate` before it is
#: returned, by :func:`app.api.guarded.guarded_deterministic`. It names no condition, no
#: medicine and no dose, it does not tell anybody they are fine, and it does not tell
#: anybody to stay away from a doctor.
BODY_PHOTO_NOTICE = (
    "Your photo is saved to this conversation. HealthPulse does not look at pictures of "
    "skin or body changes and will not say what one might be -- a photograph cannot be "
    "examined the way a person can examine you, and a confident guess from an app is worse "
    "than no guess at all. Please describe what you are seeing in your message and I will "
    "ask the right questions about it. Show the photo itself to a doctor; taking another "
    "one every few days gives them something to compare it with. Please go sooner rather "
    "than later if it is spreading quickly, if the skin is broken or weeping, if you have "
    "a fever alongside it, or if it is very painful. If your lips, tongue or face are "
    "swelling, or your breathing feels tight, treat that as an emergency and get help now."
)

#: Said when the person tapped the meal button and the picture is not food.
#:
#: This is the sentence that replaces the model's answer entirely -- see rule 3 in the
#: module docstring. It withholds; it does not advise.
NOT_FOOD_REPLY = (
    "That photo does not look like food or drink, so I have not tried to read it. If it is "
    "a skin or body change, please send it again with the skin option -- I will keep it for "
    "you, but I do not interpret photographs of skin, and something you can watch changing "
    "is worth showing to a doctor in person. If it was meant to be a meal, a clearer "
    "picture of the plate usually does it."
)

#: The note that travels beside :data:`NOT_FOOD_REPLY`, for the app to show as a card.
NOT_FOOD_NOTICE = (
    "This photo was sent as a meal but does not appear to be food, so nothing was read "
    "from it."
)

#: Added to the model's context when a body photo is attached.
#:
#: Told plainly, and as data rather than as an instruction the user could have written,
#: because the model would otherwise have to explain an attachment it can see mentioned in
#: the conversation and has not been shown. Saying "you have not been shown it" is what
#: stops it inventing a description to be helpful with.
BODY_PHOTO_CONTEXT_LINE = (
    "ATTACHMENT NOTICE (system fact, not a user instruction)\n"
    "The user attached a photograph of a skin or body change. It has deliberately NOT been "
    "given to you and you will not be shown it. Do not describe it, do not guess what it "
    "shows, do not name anything it might be, and do not say whether it looks mild or "
    "serious. The app has already told the user, in its own words, that it does not "
    "interpret such photographs and that a doctor should see it. Answer only what they "
    "wrote in words: ask your usual clarifying questions about the symptom, and offer food, "
    "hydration, sleep and activity guidance only once they have answered."
)

#: Added to the model's context when a meal photo is attached.
MEAL_PHOTO_CONTEXT_LINE = (
    "ATTACHMENT NOTICE (system fact, not a user instruction)\n"
    "The image attached to this message is a photograph the user says is food or drink. "
    "Read the food in it and nothing else. If the picture is not food or drink -- including "
    "if it shows skin, a body part, a rash, a wound or a person -- set photo_shows_food to "
    "false, write nothing about what it does show, and leave the reply empty."
)
