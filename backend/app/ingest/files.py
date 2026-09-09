"""Upload validation: size, type, and the hash that stops a second extraction.

The declared ``Content-Type`` on a multipart part is whatever the client felt like
sending. It is checked, but it is not believed: the first bytes of the file have to agree
with it. A ``.pdf`` that is really a zip is rejected here rather than sent to Gemini.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass

from app.core.errors import PayloadTooLarge, UnsupportedMedia, ValidationFailed

PDF = "application/pdf"
JPEG = "image/jpeg"
PNG = "image/png"
HEIC = "image/heic"
HEIF = "image/heif"

#: MIME type -> file extension used for the stored object.
EXTENSIONS: dict[str, str] = {
    PDF: "pdf",
    JPEG: "jpg",
    PNG: "png",
    HEIC: "heic",
    HEIF: "heif",
}

#: Aliases a phone or browser may send for the same thing.
ALIASES: dict[str, str] = {
    "image/jpg": JPEG,
    "image/pjpeg": JPEG,
    "image/x-png": PNG,
    "image/heic-sequence": HEIC,
    "image/heif-sequence": HEIF,
    "application/x-pdf": PDF,
}

#: ISO base-media brands that mean HEIC/HEIF.
_HEIF_BRANDS = frozenset(
    {b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1", b"heim", b"heis", b"hevm", b"hevs"}
)

_MIN_BYTES = 32


@dataclass(frozen=True)
class ValidatedUpload:
    """A file we are willing to store and send to the extractor."""

    data: bytes
    mime_type: str
    file_hash: str
    size: int
    filename: str

    @property
    def extension(self) -> str:
        return EXTENSIONS.get(self.mime_type, "bin")


def sha256_hex(data: bytes) -> str:
    """The content hash. Same bytes, same user, no second model call (stage 1)."""
    return hashlib.sha256(data).hexdigest()


def sniff(data: bytes) -> str | None:
    """The MIME type the *bytes* say this is, or None if we do not recognise them."""
    if len(data) < _MIN_BYTES:
        return None
    if data[:5] == b"%PDF-":
        return PDF
    if data[:3] == b"\xff\xd8\xff":
        return JPEG
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return PNG
    if data[4:8] == b"ftyp" and data[8:12] in _HEIF_BRANDS:
        return HEIC
    return None


def normalise_mime(declared: str | None) -> str | None:
    if not declared:
        return None
    value = declared.split(";")[0].strip().lower()
    return ALIASES.get(value, value)


def validate_upload(
    *,
    data: bytes,
    declared_type: str | None,
    filename: str,
    max_bytes: int,
    allowed: tuple[str, ...],
) -> ValidatedUpload:
    """Check size, type and content, then hash. Raises a typed error on every refusal."""
    size = len(data)
    if size == 0:
        raise ValidationFailed("That file was empty.")
    if size > max_bytes:
        raise PayloadTooLarge(
            f"That file is {size / 1_000_000:.1f} MB. The limit is "
            f"{max_bytes / 1_000_000:.0f} MB. A photo of each page usually fits."
        )

    sniffed = sniff(data)
    declared = normalise_mime(declared_type)

    if sniffed is None:
        raise UnsupportedMedia(
            "We could not tell what kind of file that is. Please upload a PDF, or a JPEG, "
            "PNG or HEIC photo."
        )
    if sniffed not in allowed:
        raise UnsupportedMedia()
    # HEIC and HEIF share a container, so a mismatch between those two is not a lie.
    if (
        declared is not None
        and declared in allowed
        and declared != sniffed
        and {declared, sniffed} != {HEIC, HEIF}
    ):
        raise UnsupportedMedia(
            "The file does not match the type it was sent as, so we did not open it."
        )

    return ValidatedUpload(
        data=data,
        mime_type=sniffed,
        file_hash=sha256_hex(data),
        size=size,
        filename=safe_filename(filename),
    )


def safe_filename(filename: str) -> str:
    """Keep a display name; never let it influence a storage path."""
    cleaned = (filename or "").strip().replace("\\", "/").split("/")[-1]
    cleaned = "".join(ch for ch in cleaned if ch.isprintable() and ch not in '<>:"|?*')
    return cleaned[:120] or "report"
