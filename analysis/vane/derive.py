"""Columns the station doesn't report, computed the way the app computes them.

Everything here is a pure function of the sample table. None of it is stored,
for the same reason `StationSample.dewPoint` is a computed property in Swift and
not a field: a derived number kept on disk is a number that can go stale against
the formula that made it.

Where the app already has the math, this matches it line for line, so a figure
you draw in a notebook and a figure the app puts on screen are the same claim.
"""

from __future__ import annotations

import numpy as np
import pandas as pd


def dew_point(temp_f: pd.Series, humidity: pd.Series) -> pd.Series:
    """Magnus-Tetens dew point in °F.

    Same constants and same clamp as `WeatherInterpreter.dewPointF`
    (Interpretation.swift:284). The clamp matters: relative humidity of 0 sends
    log(0) to -inf, and the station does report a flat 0 occasionally.

    PER-READING, NEVER PER-DAY. Deriving dew point from a day's mean temp and
    mean humidity gives a different and wrong number -- the function is not
    linear, so the mean of the dew points is not the dew point of the means.
    The Swift rollup is careful about this and so is this.
    """
    t = (temp_f - 32.0) * 5.0 / 9.0
    rh = humidity.clip(lower=1.0, upper=100.0)
    b, c = 17.625, 243.04
    gamma = np.log(rh / 100.0) + (b * t) / (c + t)
    return ((c * gamma) / (b - gamma)) * 9.0 / 5.0 + 32.0


def wind_vector(speed: pd.Series, direction_deg: pd.Series) -> pd.DataFrame:
    """Wind as `u` (eastward) and `v` (northward) components.

    THE REASON THIS EXISTS: you cannot average a compass bearing. A day of
    northerly wind that wobbles between 350° and 10° averages to 180° -- due
    south, the exact opposite of the truth. `DailyRecord` has no mean wind
    direction field at all for precisely this reason, and the archive keeps
    direction only at sample resolution "where it needs no reduction"
    (StationSample.swift).

    Resolving into components makes the average meaningful, because u and v are
    ordinary numbers. Average those, then use `bearing()` to come back. The
    resulting vector-mean direction is also honest in a way a circular mean
    isn't: a day of wind from every quarter produces a short vector, and its
    length tells you the direction meant little.

    Meteorological convention: direction is where the wind blows FROM, so the
    components are negated. A 90° (easterly) wind has negative u.
    """
    radians = np.deg2rad(direction_deg)
    return pd.DataFrame(
        {"u": -speed * np.sin(radians), "v": -speed * np.cos(radians)},
        index=speed.index,
    )


def bearing(u: pd.Series | float, v: pd.Series | float) -> pd.Series | float:
    """Components back to a compass bearing the wind blew FROM, 0-360°."""
    return (np.degrees(np.arctan2(-u, -v))) % 360.0


CARDINALS = ("N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
             "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW")


def cardinal(direction_deg: pd.Series) -> pd.Series:
    """Bearing to a 16-point compass label, for grouping and legends."""
    index = ((direction_deg % 360) / 22.5).round().astype("Int64") % 16
    return pd.Categorical.from_codes(
        index.fillna(-1).astype(int), categories=list(CARDINALS), ordered=True
    )


def enrich(df: pd.DataFrame) -> pd.DataFrame:
    """Add the columns you end up wanting in almost every notebook.

    Returns a copy; the archive frame is left alone.

    - `dewPoint`   -- per-reading, °F
    - `u`, `v`     -- wind components, mph
    - `day`        -- local calendar day, the archive's own key and merge unit
    - `minuteOfDay`-- 0-1439, the x-axis for laying different days over each
                      other, exactly as `StationSample.minuteOfDay` is used
    - `doy`        -- day of year, for seasonal grouping
    """
    out = df.copy()
    out["dewPoint"] = dew_point(out["airTemp"], out["humidity"])
    out[["u", "v"]] = wind_vector(out["windAvg"], out["windDirection"])
    out["day"] = out.index.strftime("%Y-%m-%d")
    out["minuteOfDay"] = out.index.hour * 60 + out.index.minute
    out["doy"] = out.index.dayofyear
    return out


def coverage(df: pd.DataFrame) -> pd.DataFrame:
    """Per-day: readings held, readings a whole day would have, and the ratio.

    The archive is emphatic that "no data" and "zero" are different answers
    (DailyRecord.swift:23), and this is the column that lets you act on it. A
    day whose afternoon is missing understates its own high, so anything about
    daily maxima should filter on this first. `DailyRecord.isReliable` is the
    same gate the app applies before it will quote a record or score a forecast.
    """
    per_day = df.groupby(df.index.normalize())
    held = per_day.size().rename("held")
    expected = (1440 // per_day["bucketMinutes"].median()).rename("expected")
    out = pd.concat([held, expected], axis=1)
    out["fraction"] = out["held"] / out["expected"]
    return out
