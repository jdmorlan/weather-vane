# Reading the Vane archive in Python

Your station's record, as pandas DataFrames. No export step — this reads the files the app
already maintains, so a notebook opened tomorrow sees yesterday's weather without you doing
anything.

## Why there's nothing to export

The archive was already built to be read from outside the app. `SampleArchive.swift:23` says it
outright: NDJSON so it's "greppable through `zgrep`, no schema to migrate, and re-interpretable
forever because nothing was reduced on the way in."

```
~/Library/Application Support/Almanac/Weather/
├── samples/2026/2026-09-15.ndjson.gz   one gzipped JSON object per reading   40 MB
├── daily/2025.json                     the app's own rollups                976 KB
├── forecasts/2026/2026-09-09.ndjson.gz what was predicted, as revisions      68 KB
└── upper-air/                          soundings                             60 KB
```

An export feature would have written a worse copy of files that already exist.

## Setup

From the repo root:

```sh
make notebook
```

That's it — it installs the environment if it's missing and opens the notebook in your browser.
Ctrl-C twice in the terminal to stop the server. `make` on its own lists the other targets
(`lab`, `sync`, `clean-cache`).

Needs `uv` (`brew install uv`) and Python 3.11+; the system 3.9 won't do.

## Use

```python
from vane import Archive, daily
from vane.derive import enrich, coverage

arc = Archive()                 # finds the archive on its own
df  = arc.samples()             # 1,946,556 rows — everything
df  = arc.samples('2025-07')    # or one month; only that year is loaded
df  = enrich(df)                # + dewPoint, u, v, day, minuteOfDay, doy
```

The frame is indexed by a tz-aware `DatetimeIndex` in the station's local zone, sorted, with the
epoch `timestamp` kept as a column — that integer is the sample's identity on the Swift side and
stays the better join key.

### The cache

First read decodes ~1,400 gzip files (~10s) and writes Parquet into `cache/`. After that, ~2s.
`cache/` is gitignored and disposable: delete it and it rebuilds, or pass `refresh=True`. The
NDJSON is truth; Parquet is only ever a faster copy.

### Timezone

Resolved from `/etc/localtime` → `America/Chicago`, matching the app's own fallback when the
station report hasn't named a zone (`StationModels.swift:81`). Pass `Archive(tz='...')` if you
move the archive to another machine. This is not cosmetic — a day boundary in the wrong zone
smears every daily min and max across two of yours, which is why `DailyRecord` insists days are
local.

### Units

Imperial, unconverted: °F, mph, inHg, in, mi. That's how `TempestClient.swift:52` fetched them, so
that's how they're stored. `vane.UNITS` maps each column to its unit so a plot can label itself.

## What's here

| file | |
|---|---|
| `vane/paths.py` | finds the archive — App Group container, then the legacy folder |
| `vane/archive.py` | `Archive.samples()`, the Parquet cache, `daily()` |
| `vane/derive.py` | dew point, wind vectors, coverage — matching the Swift |
| `notebooks/00-one-day.ipynb` | **start here** — one day of weather, no prior pandas assumed |
| `notebooks/01-first-look.ipynb` | a tour of the whole record; a reference, not a lesson |

## Three things this data will teach you

**Coverage before extremes.** 1,264 of 1,433 days are fully watched; the rest have holes. A day
missing its afternoon understates its own high, and unfiltered it looks like a cool day.
`coverage()` gives you the gate. "No data" and "zero" are different answers — `DailyRecord.swift:23`.

**You cannot average a compass bearing.** On 2025-10-30 the naive mean of `windDirection` says the
wind came from 172°. Decomposing into components and averaging those says 351°. One is 179° wrong,
and nothing warns you. `DailyRecord` has no mean-direction field for exactly this reason.

**Resolution changes the answer.** The `daily/` rollups were built from a half-hourly fetch
(`expectedSamples: 48`); your samples are at one minute. Over 305 comparable days in 2025, the
minute data finds a *higher* daily high on **89%** of them — up to 2.0°F higher, and gusts up to
3.3 mph higher. Neither table is wrong. It means never compare an extreme from one resolution
against an extreme from another.

## Not yet read

`forecasts/` — what was predicted for each day, kept as a log of revisions, with
`ForecastAccuracy.swift` as a reference implementation of the join. And `upper-air/`. Both are
straightforward additions when you want them.
