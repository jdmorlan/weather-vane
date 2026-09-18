"""Where the archive lives, and how to find it without being told.

The app resolves its data directory at launch (`AppGroup.dataDirectory` in
Weather/App/Settings.swift): the App Group container when the entitlement is in
the signed profile, and the legacy `Application Support/Almanac` folder when it
isn't. Both can exist at once during the migration -- the migration copies and
deliberately never deletes -- so this checks both and picks the one that
actually has samples in it, rather than assuming which era we're in.
"""

from __future__ import annotations

import os
from pathlib import Path

APP_GROUP_ID = "CG68B3UD28.group.jdm-solutions.vane"

#: Candidate roots, in the order the app itself would prefer them.
CANDIDATES = (
    Path.home() / "Library/Group Containers" / APP_GROUP_ID / "Weather",
    Path.home() / "Library/Application Support/Almanac/Weather",
)


def find_root(explicit: str | os.PathLike[str] | None = None) -> Path:
    """The `Weather/` directory holding `samples/`, `daily/`, `forecasts/`.

    Set ``VANE_ARCHIVE`` to override, or pass ``explicit``. Prefers a candidate
    that actually contains samples, so a half-migrated container that exists but
    is empty doesn't shadow the real record.
    """
    if explicit is not None:
        root = Path(explicit).expanduser()
        if not root.is_dir():
            raise FileNotFoundError(f"No archive at {root}")
        return root

    if env := os.environ.get("VANE_ARCHIVE"):
        return find_root(env)

    populated = [c for c in CANDIDATES if (c / "samples").is_dir() and any((c / "samples").glob("*/*.ndjson.gz"))]
    if populated:
        return populated[0]

    existing = [c for c in CANDIDATES if c.is_dir()]
    if existing:
        return existing[0]

    raise FileNotFoundError(
        "No Vane archive found. Looked in:\n  "
        + "\n  ".join(str(c) for c in CANDIDATES)
        + "\nSet VANE_ARCHIVE to point at the Weather/ directory."
    )
