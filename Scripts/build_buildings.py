import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import sys
import urllib.parse
import urllib.request

import duckdb
from shapely import from_wkb
from shapely.affinity import affine_transform
from shapely.geometry import LineString, Polygon, box
from shapely.ops import polygonize, unary_union
from shapely.strtree import STRtree


BBOX = (54.31, 24.42, 54.41, 24.52)
GBA_URL = "https://data.source.coop/tge-labs/globalbuildingatlas-lod1/e050_n25_e055_n20.parquet"
OVERPASS = ("https://overpass-api.de/api/interpreter",
            "https://overpass.private.coffee/api/interpreter")
ROOT = Path(__file__).resolve().parents[1]
SCALE = math.pi * 6_371_000 / 180


def metric(polygon):
    return affine_transform(polygon, [
        SCALE * math.cos(math.radians(24.47)), 0, 0, SCALE,
        -54.36 * SCALE * math.cos(math.radians(24.47)), -24.47 * SCALE,
    ])


def parts(geometry):
    if geometry.geom_type == "Polygon":
        return [geometry]
    if geometry.geom_type == "MultiPolygon":
        return list(geometry.geoms)
    return []


def positive(value, units=False):
    pattern = r"\s*(\d+(?:\.\d+)?)\s*(m|meters|metres|ft|')?\s*" if units else r"\s*(\d+(?:\.\d+)?)\s*"
    match = re.fullmatch(pattern, str(value).lower())
    if not match:
        return None
    number = float(match[1])
    if units and match[2] in ("ft", "'"):
        number *= 0.3048
    return number if math.isfinite(number) and number > 0 else None


def gba_rows(cache, refresh):
    path = cache / "gba.json"
    if refresh or not path.exists():
        connection = duckdb.connect()
        connection.execute("INSTALL httpfs; LOAD httpfs;")
        rows = connection.execute("""
            SELECT source, id, height, geometry
            FROM read_parquet(?)
            WHERE bbox.xmax >= ? AND bbox.ymax >= ?
              AND bbox.xmin <= ? AND bbox.ymin <= ?
            ORDER BY source, id
        """, [GBA_URL, *BBOX]).fetchall()
        connection.close()
        path.write_text(json.dumps([
            [source, identifier, height, bytes(wkb).hex()]
            for source, identifier, height, wkb in rows
        ], allow_nan=False))
    return json.loads(path.read_text())


def osm_elements(cache, refresh):
    path = cache / "osm.json"
    if refresh or not path.exists():
        west, south, east, north = BBOX
        bounds = f"{south},{west},{north},{east}"
        query = f"""[out:json][timeout:120];
        (way["building"]["height"]({bounds});
         way["building"]["building:levels"]({bounds});
         relation["building"]["height"]({bounds});
         relation["building"]["building:levels"]({bounds}););
        out geom;"""
        errors = []
        for server in OVERPASS:
            request = urllib.request.Request(
                server, urllib.parse.urlencode({"data": query}).encode(),
                headers={"User-Agent": "CoolMap-buildings/1.0 (offline hackathon data importer)"})
            try:
                with urllib.request.urlopen(request, timeout=150) as response:
                    data = json.load(response)
                if "remark" in data or "elements" not in data:
                    raise ValueError(data.get("remark", "missing elements"))
                path.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False))
                break
            except (OSError, ValueError) as error:
                errors.append(f"{server}: {error}")
                print(errors[-1], file=sys.stderr)
        else:
            raise RuntimeError("All Overpass servers failed: " + "; ".join(errors))
    return json.loads(path.read_text())["elements"]


def osm_polygons(element):
    def coordinates(geometry):
        return [(point["lon"], point["lat"]) for point in geometry]
    if element["type"] == "way":
        points = coordinates(element.get("geometry", []))
        return [Polygon(points)] if len(points) >= 4 and points[0] == points[-1] else []
    outer, inner = [], []
    for member in element.get("members", []):
        points = coordinates(member.get("geometry", []))
        if member["type"] == "way" and len(points) >= 2:
            (inner if member.get("role") == "inner" else outer).append(LineString(points))
    shells = unary_union(list(polygonize(unary_union(outer))))
    holes = unary_union(list(polygonize(unary_union(inner))))
    return parts(shells.difference(holes))


def overrides(elements):
    records = []
    for element in sorted(elements, key=lambda item: (item["type"], item["id"])):
        tags = element.get("tags", {})
        height = positive(tags.get("height"), units=True)
        source = "exact"
        if height is None:
            levels = positive(tags.get("building:levels"))
            if levels is None:
                continue
            height, source = levels * 3.5, "levelsEstimate"
        for polygon in osm_polygons(element):
            if polygon.is_valid and not polygon.is_empty:
                records.append((metric(polygon), height, source,
                                tags.get("name:en") or tags.get("name"),
                                f'{element["type"]}/{element["id"]}'))
    return records


def build(rows, osm):
    coverage = box(*BBOX)
    tree = STRtree([record[0] for record in osm])
    records = []
    for source, identifier, height, wkb in rows:
        for index, polygon in enumerate(parts(from_wkb(bytes.fromhex(wkb)))):
            if not polygon.is_valid or not polygon.intersects(coverage):
                continue
            local = metric(polygon)
            matches = []
            for candidate in tree.query(local):
                footprint, osm_height, height_source, name, osm_id = osm[int(candidate)]
                overlap = local.intersection(footprint).area
                iou = overlap / (local.area + footprint.area - overlap)
                if local.contains(footprint.centroid) or footprint.contains(local.centroid) or iou > 0.3:
                    matches.append((height_source == "exact", iou, osm_id, osm_height, height_source, name))
            if matches:
                _, _, _, resolved_height, height_source, name = max(matches)
            else:
                resolved_height, height_source, name = positive(height), "model", None
            if resolved_height is None:
                continue
            points = [(round(x, 6), round(y, 6)) for x, y in polygon.exterior.coords[:-1]]
            points = [point for i, point in enumerate(points) if point != points[i - 1]]
            if len(points) < 3:
                continue
            rounded = Polygon(points)
            if not rounded.is_valid or metric(rounded).area < 15:
                continue
            records.append({
                "id": f"gba-{source}-{identifier}-{index}",
                "footprint": [{"latitude": y, "longitude": x} for x, y in points],
                "heightMeters": round(resolved_height, 3),
                "heightSource": height_source,
                "name": name,
            })
    return sorted(records, key=lambda record: record["id"])


def main():
    parser = argparse.ArgumentParser(description="Build offline Abu Dhabi footprints: GBA (CC BY-NC) + OpenStreetMap (ODbL).")
    parser.add_argument("--cache-dir", type=Path, default=Path("/tmp/coolmap-buildings-cache"),
                        help="Keep source snapshots here for byte-identical offline reruns.")
    parser.add_argument("--refresh", action="store_true", help="Replace cached snapshots with current upstream data.")
    parser.add_argument("--output", type=Path, default=ROOT / "CoolMap/Resources/abudhabi-buildings.json")
    args = parser.parse_args()
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    rows = gba_rows(args.cache_dir, args.refresh)
    osm = overrides(osm_elements(args.cache_dir, args.refresh))
    records = build(rows, osm)
    if not records or len({record["id"] for record in records}) != len(records):
        raise ValueError("Empty dataset or duplicate building IDs")
    payload = (json.dumps(records, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode()
    if len(payload) > 15_000_000:
        raise ValueError(f"{len(payload)} bytes exceeds 15 MB; shrink BBOX explicitly before publishing")
    args.output.write_bytes(payload)
    print(f"Bbox: {BBOX}; count: {len(records)}; bytes: {len(payload)}")
    counts = Counter(record["heightSource"] for record in records)
    for source in ("exact", "levelsEstimate", "model"):
        print(f"{source}: {counts[source]} ({counts[source] / len(records):.2%})")
    print("Ten tallest (metres, source, name, GBA ID):")
    for record in sorted(records, key=lambda item: (-item["heightMeters"], item["id"]))[:10]:
        print(f'{record["heightMeters"]:.3f}\t{record["heightSource"]}\t{record["name"] or "(unnamed)"}\t{record["id"]}')
    for path in (args.cache_dir / "gba.json", args.cache_dir / "osm.json", args.output):
        print(f"SHA256 {path.name}: {hashlib.sha256(path.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
