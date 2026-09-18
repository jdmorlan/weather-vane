"""The sample archive as a DataFrame.

ONE ROW PER READING, which is the same posture `SampleArchive.swift` takes on
the Swift side: nothing is reduced on the way in, and every projection you want
-- hourly, daily, "the hours it was actually storming" -- is a groupby over this
one table rather than a different file on disk.

The archive is ~1,400 gzipped NDJSON files and about two million rows. Decoding
that from JSON takes the better part of a minute, which is fine once and
intolerable every time you restart a kernel, so the first read writes a Parquet
copy per year into `cache/` and every read after that is a second or two.
Parquet is a cache, never truth: delete `cache/` and it rebuilds from the NDJSON,
which is the only thing the app actually maintains.

UNITS ARE IMPERIAL, because that is how they were fetched and therefore how they
were stored -- `TempestClient.swift:52` asks WeatherFlow for `units_temp=f`,
`units_wind=mph`, `units_pressure=inhg`, `units_precip=in`, `units_distance=mi`.
Nothing is converted here. A column means what the station reported.
"""

from __future__ import annotations

import gzip
import json
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import pandas as pd

from .paths import find_root

#: Every column a `StationSample` can carry, with the dtype to hold it in.
#:
#: Declared rather than inferred. A day where the hub never saw a lightning
#: strike has no `strikeDistance` key at all, so inference alone gives that day a
#: different schema from its neighbours and the concat silently produces object
#: columns. Naming the schema means a missing column is NaN, which is the true
#: answer, and the dtype is the same in every year.
SCHEMA: dict[str, str] = {
    "timestamp": "int64",
    "bucketMinutes": "int16",
    "reportInterval": "Int16",
    "airTemp": "float32",
    "humidity": "float32",
    "stationPressure": "float32",
    "seaLevelPressure": "float32",
    "windLull": "float32",
    "windAvg": "float32",
    "windGust": "float32",
    "windDirection": "float32",
    "uv": "float32",
    "solarRadiation": "float32",
    "illuminance": "float32",
    "precip": "float32",
    "precipCorrected": "float32",
    "precipType": "float32",
    "strikeCount": "float32",
    "strikeDistance": "float32",
}

#: What each column is measured in. Carried so a plot can label its own axis and
#: so nobody has to go read the Swift to find out whether pressure is inHg.
UNITS: dict[str, str] = {
    "airTemp": "°F",
    "dewPoint": "°F",
    "humidity": "%",
    "stationPressure": "inHg",
    "seaLevelPressure": "inHg",
    "windLull": "mph",
    "windAvg": "mph",
    "windGust": "mph",
    "windDirection": "° from",
    "uv": "index",
    "solarRadiation": "W/m²",
    "illuminance": "lux",
    "precip": "in",
    "precipCorrected": "in",
    "strikeDistance": "mi",
}


@dataclass(frozen=True)
class Archive:
    """A handle on one station's record.

    >>> arc = Archive()
    >>> df = arc.samples("2025-06")
    >>> df["airTemp"].resample("1h").max().head()
    """

    root: Path
    tz: str
    cache: Path

    def __init__(
        self,
        root: str | Path | None = None,
        tz: str | None = None,
        cache: str | Path | None = None,
    ) -> None:
        resolved = find_root(root)
        object.__setattr__(self, "root", resolved)
        # The app falls back to the machine's own zone when the station report
        # hasn't named one (StationModels.swift:81), and so do we. Pass `tz`
        # explicitly if you move the archive to another machine -- a day
        # boundary in the wrong zone corrupts every daily min and max, which is
        # the whole reason DailyRecord insists days are local.
        object.__setattr__(self, "tz", tz or local_zone())
        object.__setattr__(self, "cache", Path(cache) if cache else Path(__file__).resolve().parent.parent / "cache")

    # -- what's on disk -------------------------------------------------

    @property
    def sample_dir(self) -> Path:
        return self.root / "samples"

    def days(self) -> list[str]:
        """Every `yyyy-MM-dd` the sample archive holds, ascending."""
        return sorted(p.name.removesuffix(".ndjson.gz") for p in self.sample_dir.glob("*/*.ndjson.gz"))

    def years(self) -> list[int]:
        return sorted({int(p.name) for p in self.sample_dir.iterdir() if p.name.isdigit()})

    # -- reading --------------------------------------------------------

    def samples(self, period: str | None = None, *, refresh: bool = False) -> pd.DataFrame:
        """Readings as a tz-aware, time-indexed frame.

        `period` is anything pandas can read as a span -- `"2025"`, `"2025-06"`,
        `"2025-06-15"` -- or None for the whole record. Only the years the span
        touches are loaded, so a single month never pays for four years.
        """
        wanted = self.years() if period is None else _years_in(period)
        frames = [self._year(y, refresh=refresh) for y in wanted if y in self.years()]
        if not frames:
            return _empty()
        df = pd.concat(frames) if len(frames) > 1 else frames[0]
        if period is not None:
            df = df.loc[period]
        return df

    def _year(self, year: int, *, refresh: bool = False) -> pd.DataFrame:
        parquet = self.cache / f"samples-{year}.parquet"
        if parquet.exists() and not refresh:
            return pd.read_parquet(parquet)
        df = self._decode_year(year)
        self.cache.mkdir(parents=True, exist_ok=True)
        df.to_parquet(parquet)
        return df

    def _decode_year(self, year: int) -> pd.DataFrame:
        files = sorted((self.sample_dir / str(year)).glob("*.ndjson.gz"))
        rows: list[dict] = []
        for path in files:
            with gzip.open(path, "rt") as fh:
                rows.extend(json.loads(line) for line in fh if line.strip())
        if not rows:
            return _empty()
        df = pd.DataFrame.from_records(rows)
        for column, dtype in SCHEMA.items():
            if column not in df:
                df[column] = pd.NA
            df[column] = df[column].astype(dtype)
        df = df[list(SCHEMA)]
        return _index(df, self.tz)


def local_zone() -> str:
    """This machine's IANA zone name, e.g. `America/Chicago`.

    Read from the `/etc/localtime` symlink rather than `time.tzname`, which
    gives an abbreviation ("CDT") that no zone database can resolve and that
    silently means something different in another hemisphere.
    """
    link = Path("/etc/localtime")
    if link.is_symlink():
        parts = link.resolve().parts
        if "zoneinfo" in parts:
            return "/".join(parts[parts.index("zoneinfo") + 1 :])
    return datetime.now().astimezone().tzname() or "UTC"


def _empty() -> pd.DataFrame:
    df = pd.DataFrame({c: pd.Series(dtype=d) for c, d in SCHEMA.items()})
    return _index(df, "UTC")


def _index(df: pd.DataFrame, tz: str) -> pd.DataFrame:
    """Timestamps become a sorted, tz-aware index; `timestamp` stays as a column.

    The epoch column is kept deliberately. It is the sample's identity on the
    Swift side -- a station cannot report two readings for one instant -- so it
    is what you join and de-duplicate on, and an index that has been converted
    to a local zone is a worse key than the integer it came from.
    """
    when = pd.to_datetime(df["timestamp"], unit="s", utc=True).dt.tz_convert(tz)
    return df.set_index(pd.DatetimeIndex(when, name="time")).sort_index()


def _years_in(period: str) -> list[int]:
    span = pd.Period(period)
    return list(range(span.start_time.year, span.end_time.year + 1))


# -- the rollup, as an answer key ---------------------------------------


def daily(archive: Archive, year: int | None = None) -> pd.DataFrame:
    """The app's own `DailyRecord` rollups, indexed by local day.

    Not a substitute for the samples -- it is the ANSWER KEY. Every daily figure
    you compute from the sample table has a counterpart here that the Swift
    already computed, so "is my groupby right" is a question you can actually
    settle instead of squint at.

    Expect disagreement on the extremes, and expect the samples to win. Compare
    `expectedSamples` (48 -- these rollups were built from a half-hourly fetch)
    against the minute-resolution sample archive: a 30-minute series simply
    cannot see a gust that lasted four minutes. That isn't an error in either
    table. It is the same point `SampleMerge.shouldReplace` makes when it says
    finer resolution wins, and it is the single best reason to work from the
    samples rather than from anyone's rollup.
    """
    years = archive.years() if year is None else [year]
    rows: list[dict] = []
    for y in years:
        path = archive.root / "daily" / f"{y}.json"
        if path.exists():
            rows.extend(json.loads(path.read_text()))
    if not rows:
        return pd.DataFrame()
    df = pd.DataFrame.from_records(rows).set_index("day").sort_index()
    df["fraction"] = df["sampleCount"] / df["expectedSamples"]
    return df
