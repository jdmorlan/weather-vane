#!/bin/sh
#
#  build-county-boundaries.sh — the county lines the map draws, rebuilt from the
#  Census Bureau's own file.
#
#  WHERE IT COMES FROM. The 2024 cartographic boundary file at 1:5,000,000
#  (`cb_2024_us_county_5m`) — the Census Bureau's generalised county outlines,
#  made for exactly this: drawing counties on a map rather than surveying them.
#  1:20,000,000 was half a megabyte smaller and visibly wrong at the radar's
#  default zoom, where a county line wandering a mile off the river it follows
#  reads as a mistake. The 1:500,000 file is sharper than anything the outlooks
#  drawn over it can claim.
#
#  WHAT IT KEEPS. The fifty states, DC and Puerto Rico. The Pacific territories
#  and the Virgin Islands are outside every outlook SPC and WPC issue, so their
#  lines would only ever be drawn under nothing.
#
#  WHY NOT GeoJSON AS-IS. Two reasons, both about the rounding. Four decimals is
#  about 11 m, far finer than a 1:5M outline is true to, and it takes the file
#  from 13 MB to under 6. But GDAL's own `COORDINATE_PRECISION` makes the rounded
#  geometry VALID as it goes, and eight counties come out as a polygon plus a
#  stray LineString sliver. An outline does not care about validity, so the
#  rounding happens here instead, and the rings are stored flat — every ring is
#  just a line to stroke, outer or hole alike.
#
#  Needs `ogr2ogr` (GDAL) and `python3`. Run from anywhere; rerun when the Census
#  Bureau publishes a new vintage and bump the year below.
#

set -eu

YEAR=2024
SCALE=5m
NAME="cb_${YEAR}_us_county_${SCALE}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Packages/WeatherKit/Sources/WeatherKit/Resources/census-counties-${SCALE}.json.gz"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/$NAME.zip" "https://www2.census.gov/geo/tiger/GENZ${YEAR}/shp/$NAME.zip"
ogr2ogr -f GeoJSON -select GEOID,NAME,STUSPS \
    -where "STUSPS NOT IN ('AS','GU','MP','VI')" \
    -t_srs EPSG:4326 \
    "$WORK/counties.geojson" "/vsizip/$WORK/$NAME.zip"

python3 - "$WORK/counties.geojson" "$WORK/counties.json" "$NAME" <<'PY'
import json, sys

source, target, name = sys.argv[1:]
counties = []
for feature in json.load(open(source))["features"]:
    geometry = feature["geometry"]
    polygons = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]
    rings = []
    for polygon in polygons:
        for ring in polygon:
            flat, last = [], None
            for lon, lat in ring:
                point = (round(lon, 4), round(lat, 4))
                if point != last:
                    flat += point
                    last = point
            # A ring that rounding collapsed to a line has nothing to outline.
            if len(flat) >= 8:
                rings.append(flat)
    props = feature["properties"]
    counties.append({"geoid": props["GEOID"], "name": props["NAME"],
                     "state": props["STUSPS"], "rings": rings})

counties.sort(key=lambda c: c["geoid"])
json.dump({"source": f"US Census Bureau, {name}", "counties": counties},
          open(target, "w"), separators=(",", ":"))
PY

mkdir -p "$(dirname "$OUT")"
# -n: no name or timestamp in the header, so an unchanged source rebuilds to
# identical bytes and git sees no change.
gzip -9 -n -c "$WORK/counties.json" > "$OUT"
echo "Wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
