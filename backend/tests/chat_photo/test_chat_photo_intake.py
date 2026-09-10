"""Photographs in chat: what is sent to a model, and -- mostly -- what is not.

The feature exists because the owner asked for a camera in the chat composer, for two
things: *"hey, I ate this and these items"*, and *"if there are any skin allergies, he can
take a photo"*. Those two need opposite handling, and the tests below are the enforcement
of that, in the same spirit as ``tests/api/test_guard_enforcement.py``: the interesting
assertions are the negative ones.

The single most important test in this file is
:func:`test_a_body_photo_is_never_given_to_the_model`. If it ever goes green for the wrong
reason, this product has started guessing at photographs of people's skin.
"""

from __future__ import annotations

from typing import Any

import pytest

from app.rules import chat_photos
from app.rules.chat_photos import ChatPhotoKind
from tests.api.conftest import consented, request
from tests.conftest import USER_ID

#: Enough bytes for ``app.ingest.files.sniff`` to have something to look at, with a real
#: header on the front. The content is irrelevant -- nothing in this suite decodes a
#: picture, and the fake Gemini never sees a real one.
JPEG = b"\xff\xd8\xff" + b"j" * 64
PNG = b"\x89PNG\r\n\x1a\n" + b"p" * 64
PDF = b"%PDF-1.7\n" + b"d" * 64


def upload(client: Any, auth: dict[str, str], kind: str, data: bytes = JPEG, **kwargs: Any):
    return request(
        client,
        "POST",
        f"/v1/chat/photos/{kind}",
        headers=auth,
        files={"file": (kwargs.pop("filename", "photo.jpg"), data, kwargs.pop("mime", "image/jpeg"))},
    )


def send(client: Any, auth: dict[str, str], message: str, **body: Any):
    return request(
        client, "POST", "/v1/chat/messages", headers=auth, json={"message": message, **body}
    )


def parts_of(call: dict[str, Any]) -> Any:
    return call["parts"]


def has_image(call: dict[str, Any]) -> bool:
    """True when this Gemini call carried a picture."""
    parts = parts_of(call)
    if isinstance(parts, str):
        return False
    return any(isinstance(part, dict) and "inline_data" in part for part in parts)


# ------------------------------------------------------------------- the id itself


def test_a_photo_id_carries_its_kind_and_round_trips() -> None:
    photo_id = chat_photos.new_photo_id(ChatPhotoKind.BODY, "image/jpeg")
    parsed = chat_photos.parse_photo_id(photo_id)
    assert parsed is not None
    assert parsed.kind is ChatPhotoKind.BODY
    assert parsed.mime_type == "image/jpeg"
    assert parsed.storage_path(USER_ID) == f"{USER_ID}/{photo_id}"


@pytest.mark.parametrize(
    "hostile",
    [
        "",
        "../../../etc/passwd",
        "../other-user/secret-meal.jpg",
        f"{'a' * 32}-meal.jpg/../../x",
        f"{'a' * 32}-meal.pdf",
        f"{'a' * 32}-selfie.jpg",
        f"{'A' * 32}-meal.jpg",
        f"{'a' * 31}-meal.jpg",
        f"{'a' * 32}-meal.jpg\n",
    ],
)
def test_an_id_we_did_not_mint_is_not_a_photo(hostile: str) -> None:
    """The id is concatenated onto the user's storage folder, so its shape is the check."""
    assert chat_photos.parse_photo_id(hostile) is None


def test_the_stored_path_is_flat_so_the_deletion_sweep_finds_it() -> None:
    """One folder deep, beside the report files.

    Not decoration: ``DeletionRepository.storage_paths`` lists a single prefix, and
    Supabase's listing is not recursive. A photo in ``<user>/chat/...`` would quietly
    survive "delete all my health data".
    """
    photo_id = chat_photos.new_photo_id(ChatPhotoKind.MEAL, "image/png")
    path = chat_photos.parse_photo_id(photo_id).storage_path(USER_ID)
    assert path.count("/") == 1
    assert path.split("/")[0] == USER_ID


# ------------------------------------------------------------------------- upload


def test_uploading_a_photo_stores_it_and_calls_no_model(client, auth, store, gemini):
    consented(store)
    response = upload(client, auth, "meal")

    assert response.status_code == 201, response.text
    body = response.json()
    assert body["kind"] == "meal"
    assert body["label"] == "Photo of a meal"
    assert body["notices"] == []
    assert store.storage[f"{USER_ID}/{body['photo_id']}"] == JPEG
    assert gemini.calls == [], "storing a photo must not cost a model call"


def test_a_body_photo_is_told_at_once_that_it_will_not_be_interpreted(client, auth, store):
    consented(store)
    response = upload(client, auth, "body", data=PNG, mime="image/png")

    assert response.status_code == 201, response.text
    body = response.json()
    assert body["photo_id"].endswith("-body.png")
    assert body["label"] == "Photo of a skin or body concern"
    # Said before the person waits for a reply, not after it.
    assert body["notices"] == [chat_photos.BODY_PHOTO_NOTICE]


def test_a_pdf_is_not_a_chat_photo(client, auth, store):
    """A document belongs on the Reports tab, which reads it properly."""
    consented(store)
    response = upload(client, auth, "meal", data=PDF, filename="report.pdf", mime="application/pdf")
    assert response.status_code == 415


def test_a_kind_we_do_not_have_is_not_a_route(client, auth, store):
    """There is no third kind and nothing defaults, so an unknown one is refused."""
    consented(store)
    assert upload(client, auth, "skin").status_code == 422


def test_a_photo_needs_consent(client, auth, store):
    assert upload(client, auth, "meal").status_code == 403


# ------------------------------------------------------ the message that carries it


def test_a_meal_photo_is_given_to_the_model_as_an_image(client, auth, store, gemini):
    consented(store)
    photo_id = upload(client, auth, "meal").json()["photo_id"]
    gemini.queue(
        {
            "photo_shows_food": True,
            "reply": "Two idlis and sambar. A good start; add a boiled egg for protein.",
            "follow_up_questions": [],
            "needs_more_info": False,
        }
    )

    response = send(client, auth, "I ate this", photo_ids=[photo_id])

    assert response.status_code == 200, response.text
    body = response.json()
    assert "Two idlis and sambar" in body["reply"]
    assert body["photo_notes"] == []
    assert has_image(gemini.calls[0]), "the meal photo never reached the model"
    # The image leads and the words follow, the order the report extractor already uses.
    assert "inline_data" in parts_of(gemini.calls[0])[0]
    assert parts_of(gemini.calls[0])[0]["inline_data"]["mime_type"] == "image/jpeg"


def test_a_body_photo_is_never_given_to_the_model(client, auth, store, gemini):
    """The one that matters.

    A photograph of skin is accepted, stored, and answered -- but the picture itself does
    not leave this service. There is no prompt careful enough to make sending it safe,
    because the deterministic validator reads words and an image has none: it would catch
    "you have eczema" and it would not catch a fluent, drug-free, correctly-spelled
    sentence that talks somebody out of going to a doctor.
    """
    consented(store)
    photo_id = upload(client, auth, "body").json()["photo_id"]
    gemini.queue(
        {
            "reply": "Thanks for telling me. A few questions so I understand it better.",
            "follow_up_questions": ["When did you first notice it?"],
            "needs_more_info": True,
        }
    )

    response = send(client, auth, "this patch on my arm has been itching", photo_ids=[photo_id])

    assert response.status_code == 200, response.text
    assert gemini.calls, "the message itself is still answered"
    for call in gemini.calls:
        assert not has_image(call), "a photograph of skin was sent to a model"

    body = response.json()
    # The refusal is deterministic text, and it is on the reply as well as on the upload.
    assert body["photo_notes"] == [chat_photos.BODY_PHOTO_NOTICE]
    # The model is told the picture exists and is forbidden to guess at it, or it invents
    # a description to be helpful with.
    prose = parts_of(gemini.calls[0])
    assert "deliberately NOT been given to you" in prose


def test_mixing_a_body_photo_in_holds_every_image_back(client, auth, store, gemini):
    """The strict collapse: one skin photo on a message stops all of them going up."""
    consented(store)
    meal = upload(client, auth, "meal").json()["photo_id"]
    body_photo = upload(client, auth, "body").json()["photo_id"]
    gemini.queue(
        {"reply": "Tell me more.", "follow_up_questions": [], "needs_more_info": True}
    )

    response = send(client, auth, "dinner, and this rash", photo_ids=[meal, body_photo])

    assert response.status_code == 200, response.text
    assert not has_image(gemini.calls[0])
    assert response.json()["photo_notes"] == [chat_photos.BODY_PHOTO_NOTICE]


def test_a_meal_photo_that_is_not_food_has_the_model_answer_thrown_away(
    client, auth, store, gemini
):
    """Somebody photographed a rash and tapped the food button.

    This is the failure mode the whole design is aimed at. The model is allowed to say
    "that is not food"; it is not allowed to say what it is instead, and whatever it wrote
    is discarded unread in favour of our own sentence.
    """
    consented(store)
    photo_id = upload(client, auth, "meal").json()["photo_id"]
    gemini.queue(
        {
            "photo_shows_food": False,
            "reply": "That is a red scaly patch on a forearm, most likely eczema.",
            "follow_up_questions": ["Have you used a moisturiser on it?"],
            "needs_more_info": False,
        }
    )

    response = send(client, auth, "I ate this", photo_ids=[photo_id])

    assert response.status_code == 200, response.text
    body = response.json()
    assert chat_photos.NOT_FOOD_REPLY in body["reply"]
    assert "eczema" not in response.text.lower()
    assert "forearm" not in response.text.lower()
    assert body["follow_up_questions"] == []
    assert body["needs_more_info"] is False
    assert body["photo_notes"] == [chat_photos.NOT_FOOD_NOTICE]
    # And nothing the model wrote about the picture was stored either.
    stored = [row["content"] for row in store.rows("chat_messages") if row["role"] == "assistant"]
    assert "eczema" not in stored[0].lower()


def test_relabelling_a_body_photo_as_a_meal_does_not_get_it_read(client, auth, store, gemini):
    """The kind is part of the stored object's name, not a flag we trust.

    Editing ``-body`` to ``-meal`` on the way back in does not re-label the picture: it
    names a file that was never written.
    """
    consented(store)
    photo_id = upload(client, auth, "body").json()["photo_id"]
    forged = photo_id.replace("-body.", "-meal.")

    response = send(client, auth, "I ate this", photo_ids=[forged])

    # The status is left loose on purpose: real storage answers a missing object
    # with 404, and the in-memory one in ``tests/api/conftest.py`` raises a
    # KeyError that the error middleware turns into a 500. Either way the request
    # does not succeed. What is asserted precisely is the part that matters.
    assert response.status_code >= 400, response.text
    for call in gemini.calls:
        assert not has_image(call), "a photo uploaded as skin was read as food"


def test_an_id_we_did_not_mint_is_refused_before_any_storage_read(client, auth, store, gemini):
    consented(store)
    response = send(client, auth, "look at this", photo_ids=["../../secrets/key.jpg"])
    assert response.status_code == 422
    assert gemini.calls == []


def test_a_photo_message_still_runs_the_symptom_rules_first(client, auth, store, gemini):
    """The photo path changes nothing about stage 5. Words are still read by rules."""
    consented(store)
    photo_id = upload(client, auth, "body").json()["photo_id"]
    gemini.queue(
        {"reply": "Rest and drink water.", "follow_up_questions": [], "needs_more_info": False}
    )

    response = send(
        client,
        auth,
        "this rash, and I have crushing chest pain going down my left arm",
        photo_ids=[photo_id],
    )

    body = response.json()
    assert body["escalation"] == "urgent"
    assert body["red_flags"]
    assert body["reply"].startswith("GET MEDICAL CARE NOW")


# ----------------------------------------------------------- what the history shows


def test_the_photo_is_recorded_on_the_message_and_named_in_the_conversation(
    client, auth, store, gemini
):
    consented(store)
    photo_id = upload(client, auth, "meal").json()["photo_id"]
    gemini.queue(
        {
            "photo_shows_food": True,
            "reply": "Looks like a balanced plate.",
            "follow_up_questions": [],
            "needs_more_info": False,
        }
    )
    thread_id = send(client, auth, "I ate this", photo_ids=[photo_id]).json()["thread_id"]

    stored = next(row for row in store.rows("chat_messages") if row["role"] == "user")
    assert stored["attachments"] == [
        {
            "type": "chat_photo",
            "kind": "meal",
            "photo_id": photo_id,
            "storage_path": f"{USER_ID}/{photo_id}",
        }
    ]

    messages = request(
        client, "GET", f"/v1/chat/threads/{thread_id}/messages", headers=auth
    ).json()
    mine = next(row for row in messages if row["role"] == "user")
    # Our own words for it, never the file name off somebody's phone.
    assert mine["attachments"] == ["Photo of a meal"]


# -------------------------------------------------------------- the privacy promise


def test_deleting_everything_removes_a_chat_photo_too(client, auth, store, gemini):
    """The promise in CLAUDE.md is that deletion takes the files as well as the rows."""
    consented(store)
    photo_id = upload(client, auth, "body").json()["photo_id"]
    assert f"{USER_ID}/{photo_id}" in store.storage

    response = request(
        client,
        "POST",
        "/v1/privacy/delete",
        headers=auth,
        json={"confirm": "DELETE MY HEALTH DATA"},
    )

    assert response.status_code == 200, response.text
    assert f"{USER_ID}/{photo_id}" not in store.storage
    assert response.json()["objects_deleted"] >= 1


def test_the_export_asks_for_the_column_a_photo_is_recorded_in() -> None:
    """The column list is the real contract, so assert on it directly.

    The in-memory PostgREST in ``tests/api/conftest.py`` returns whole rows and ignores the
    columns asked for, so an end-to-end export assertion passes whether or not this list is
    right. Against the real service it would not. Checking the constant is the only version
    of this test that cannot go green for the wrong reason.
    """
    from app.repositories.privacy import EXPORT_TABLES

    columns = dict(EXPORT_TABLES)["chat_messages"].split(",")
    assert "attachments" in columns, (
        "a stored photo the export does not mention is a promise half kept"
    )


def test_the_export_carries_the_fact_that_a_photo_was_sent(client, auth, store, gemini):
    """Metadata, not the picture -- the same deal the report files already get."""
    consented(store)
    photo_id = upload(client, auth, "meal").json()["photo_id"]
    gemini.queue(
        {
            "photo_shows_food": True,
            "reply": "Nice plate.",
            "follow_up_questions": [],
            "needs_more_info": False,
        }
    )
    send(client, auth, "I ate this", photo_ids=[photo_id])

    export = request(client, "GET", "/v1/privacy/export", headers=auth).json()
    messages = export["tables"]["chat_messages"]
    assert any(photo_id in str(row.get("attachments")) for row in messages), (
        "a stored photo that the export does not mention is a promise half kept"
    )
