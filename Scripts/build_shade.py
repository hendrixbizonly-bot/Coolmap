import argparse
from collections import Counter
import io
import json
import math
from pathlib import Path
import re
import urllib.parse
import urllib.request

import duckdb
import numpy as np
import rasterio
from rasterio.features import shapes, geometry_mask
from rasterio.warp import transform as warp, transform_bounds
from rasterio.windows import from_bounds
from scipy import ndimage
from shapely.geometry import LineString, Point, Polygon, box, shape, mapping
from shapely.ops import transform

BBOX = (54.31, 24.42, 54.41, 24.52)
MIN_CROWN_AREA = 30
CELL_SIZE = 25
INDEX = "https://data.source.coop/tge-labs/meta-chm-v2/tiles.parquet"
UA = "CoolMap-hackathon/1.0 (shade-data importer)"
ROOT = Path(__file__).resolve().parents[1]


def project(geometry, source, target):
    return transform(lambda x, y, z=None: warp(source, target, x, y), geometry)


def request(url, data=None):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=180) as response:
        return response.read()


def meters(text, fallback):
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*(m|meters|metres|ft|')?\s*", text or "")
    value = float(match[1]) * (0.3048 if match[2] in ("ft", "'") else 1) if match else fallback
    return value if math.isfinite(value) and value > 0 else fallback


def record(identifier, polygon, height, minimum, transmission, kind, source="fallback"):
    coords = list(project(polygon, "EPSG:32640", "EPSG:4326").exterior.coords)[:-1]
    precision = 5 if kind == "tree" else 6
    coords = [(round(x, precision), round(y, precision)) for x, y in coords]
    footprint = [{"latitude": y, "longitude": x} for x, y in coords]
    height, minimum = round(float(height), 2), round(float(minimum), 2)
    return dict(id=identifier, footprint=footprint, heightMeters=int(height) if height.is_integer() else height,
                heightSource=source, minHeightMeters=int(minimum) if minimum.is_integer() else minimum,
                transmissivity=transmission, kind=kind)


def polygons(geometry):
    if geometry.geom_type == "Polygon":
        yield geometry
    elif hasattr(geometry, "geoms"):
        for part in geometry.geoms:
            yield from polygons(part)


def fit_budget(records, stats):
    selected, used = [], 3
    stats["retainedAreaM2"] = 0
    for item in sorted(records, key=lambda r: -r.get("_pixelArea", float("inf"))):
        area = item.pop("_pixelArea", 0)
        cost = len(json.dumps(item, separators=(",", ":")).encode()) + 1
        if item["kind"] != "tree" and used + cost > 10_000_000:
            raise ValueError("Structures alone exceed the output budget")
        if used + cost <= 10_000_000:
            selected.append(item)
            used += cost
            stats["retainedAreaM2"] += area
    return selected


def crowns(data, affine, crs, tile, minimum_area=MIN_CROWN_AREA, stats=None):
    labels, count = ndimage.label(data >= 3, structure=np.ones((3, 3)))
    slices = ndimage.find_objects(labels)
    for component in range(1, count + 1):
        region = slices[component - 1]
        mask = labels[region] == component
        local = affine * rasterio.Affine.translation(region[1].start, region[0].start)
        pieces = [shape(g) for g, value in shapes(mask.astype("uint8"), mask=mask,
                                                 transform=local, connectivity=8) if value]
        pixel_polygon = project(pieces[0], crs, "EPSG:32640")
        if stats is not None:
            stats["candidateAreaM2"] += pixel_polygon.area
        if pixel_polygon.area < minimum_area:
            continue
        source = pixel_polygon.buffer(0)
        if source.area > 200:
            left, bottom, right, top = source.bounds
            cells = (source.intersection(box(x, y, x + CELL_SIZE, y + CELL_SIZE))
                     for x in range(math.floor(left / CELL_SIZE) * CELL_SIZE, math.ceil(right), CELL_SIZE)
                     for y in range(math.floor(bottom / CELL_SIZE) * CELL_SIZE, math.ceil(top), CELL_SIZE))
        else:
            cells = [source]
        for cell in cells:
            for piece in polygons(cell):
                if piece.area < minimum_area:
                    continue
                tolerance = 0.6
                polygon = piece.simplify(tolerance, preserve_topology=True)
                while len(polygon.exterior.coords) > 9:
                    tolerance *= 1.5
                    polygon = piece.simplify(tolerance, preserve_topology=True)
                raster_piece = project(piece, "EPSG:32640", crs)
                window = from_bounds(*raster_piece.bounds, local)
                r0, c0 = max(0, math.floor(window.row_off)), max(0, math.floor(window.col_off))
                r1, c1 = min(mask.shape[0], math.ceil(window.row_off + window.height)), min(mask.shape[1], math.ceil(window.col_off + window.width))
                inside = geometry_mask([mapping(raster_piece)], out_shape=(r1-r0, c1-c0),
                                       transform=local * rasterio.Affine.translation(c0, r0), invert=True)
                pixels = data[region][r0:r1, c0:c1][inside & mask[r0:r1, c0:c1]]
                if not pixels.size:
                    continue
                height = float(np.percentile(pixels, 90))
                item = record(f"meta-{tile}-{component}", polygon, height, height * 0.5, 0.65, "tree")
                output = project(Polygon([(p["longitude"], p["latitude"]) for p in item["footprint"]]),
                                 "EPSG:4326", "EPSG:32640")
                if not output.is_valid or not minimum_area <= output.area <= piece.area * 1.15:
                    continue
                if stats is not None:
                    stats["retainedAreaM2"] += piece.area
                item["_pixelArea"] = piece.area
                yield item


def trees(bbox, cache, stats=None):
    west, south, east, north = bbox
    index_cache = cache / "tiles.json"
    if index_cache.exists():
        tiles = json.loads(index_cache.read_text())
    else:
        connection = duckdb.connect()
        connection.execute("INSTALL httpfs; LOAD httpfs;")
        tiles = connection.execute(
            "SELECT quadkey,cog_url FROM read_parquet(?) WHERE bbox.xmin < ? "
            "AND bbox.xmax > ? AND bbox.ymin < ? AND bbox.ymax > ? ORDER BY quadkey",
            [INDEX, east, west, north, south]).fetchall()
        index_cache.write_text(json.dumps(tiles))
    if not tiles:
        raise ValueError("No Meta canopy tiles intersect the requested bbox")
    for tile, url in tiles:
        path = cache / f"{tile}.tif"
        if not path.exists():
            with rasterio.open(url) as dataset:
                bounds = transform_bounds("EPSG:4326", dataset.crs, *bbox)
                window = from_bounds(*bounds, dataset.transform).round_offsets().round_lengths()
                window = window.intersection(rasterio.windows.Window(0, 0, dataset.width, dataset.height))
                data = dataset.read(1, window=window, masked=True).filled(0)
                profile = dataset.profile.copy()
                profile.update(width=data.shape[1], height=data.shape[0], count=1,
                               transform=dataset.window_transform(window), compress="deflate")
                with rasterio.open(path, "w", **profile) as output:
                    output.write(data, 1)
        with rasterio.open(path) as dataset:
            data, affine, crs = dataset.read(1), dataset.transform, dataset.crs
        yield from crowns(data, affine, crs, tile, stats=stats)


def structure(element):
    tags = element.get("tags", {})
    if "highway" in tags and tags.get("covered") in ("yes", "arcade", "colonnade"):
        kind, minimum, height, width = "covered", 2.5, 4, 3
    elif tags.get("building") == "roof" or tags.get("man_made") == "canopy":
        kind, minimum, height, width = "canopy", 2.5, meters(tags.get("height"), 4), None
    elif tags.get("amenity") == "shelter":
        kind, minimum, height, width = "shelter", 2, 3, None
    elif tags.get("bridge") in ("yes", "viaduct"):
        kind, minimum, height, width = "bridge", 5, 7, meters(tags.get("width"), 8)
    else:
        return None
    if element["type"] == "node" and kind == "shelter":
        point = project(Point(element["lon"], element["lat"]), "EPSG:4326", "EPSG:32640")
        polygon = box(point.x - 1.5, point.y - 1, point.x + 1.5, point.y + 1)
    else:
        coords = [(p["lon"], p["lat"]) for p in element.get("geometry", [])]
        if len(coords) < 2:
            return None
        if width is not None:
            polygon = project(LineString(coords), "EPSG:4326", "EPSG:32640").buffer(width / 2, cap_style=2)
        elif len(coords) >= 4 and coords[0] == coords[-1]:
            polygon = project(Polygon(coords), "EPSG:4326", "EPSG:32640")
        else:
            return None
    if kind == "bridge":
        polygon = Polygon(polygon.exterior)
    if not polygon.is_valid or polygon.is_empty or polygon.area <= 0 or height <= minimum:
        return None
    transmission = 0.1 if kind == "canopy" and tags.get("material") == "fabric" else 0
    source = "exact" if kind == "canopy" and meters(tags.get("height"), 0) > 0 else "fallback"
    return record(f"osm-{element['type']}-{element['id']}", polygon, height,
                  minimum, transmission, kind, source)


def structures(bbox, cache):
    west, south, east, north = bbox
    path = cache / "osm.json"
    if not path.exists():
        bounds = f"{south},{west},{north},{east}"
        query = (f'[out:json][timeout:120];('
                 f'way["highway"]["covered"~"^(yes|arcade|colonnade)$"]({bounds});'
                 f'way["building"="roof"]({bounds});way["man_made"="canopy"]({bounds});'
                 f'nwr["amenity"="shelter"]({bounds});'
                 f'way["bridge"~"^(yes|viaduct)$"]({bounds}););out geom;')
        for host in ("overpass-api.de", "overpass.private.coffee"):
            try:
                payload = json.loads(request(f"https://{host}/api/interpreter",
                                             urllib.parse.urlencode({"data": query}).encode()))
                if payload.get("remark") or "elements" not in payload:
                    raise ValueError(f"Incomplete Overpass response: {payload.get('remark')}")
                path.write_text(json.dumps(payload))
                break
            except Exception:
                if host == "overpass.private.coffee":
                    raise
    for element in json.loads(path.read_text())["elements"]:
        result = structure(element)
        if result:
            yield result


def preview(records, path, cache):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    polygons = [project(Polygon([(p["longitude"], p["latitude"]) for p in r["footprint"]]),
                        "EPSG:4326", "EPSG:32640") for r in records if r["kind"] == "tree"]
    x, y = 471, 5419
    bounds = (x * 500, y * 500, (x + 1) * 500, (y + 1) * 500)
    block = box(*bounds)
    image_path = cache / f"preview-satellite-{x}-{y}.png"
    if not image_path.exists():
        params = urllib.parse.urlencode(dict(bbox=",".join(map(str, bounds)), bboxSR=32640,
                                            imageSR=32640, size="900,900", format="png", f="image"))
        image_path.write_bytes(request(
            "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/export?" + params))
    image = plt.imread(io.BytesIO(image_path.read_bytes()), format="png")
    fig, ax = plt.subplots(figsize=(7, 7), dpi=100)
    ax.imshow(image, extent=(bounds[0], bounds[2], bounds[1], bounds[3]))
    selected = [p for p in polygons if p.intersects(block)]
    for polygon in selected:
        px, py = polygon.exterior.xy
        ax.fill(px, py, facecolor="#30ff70", edgecolor="#aaffaa", alpha=0.3, linewidth=0.5)
    ax.set(xlim=(bounds[0], bounds[2]), ylim=(bounds[1], bounds[3]), aspect="equal",
           title=f"Abu Dhabi: {len(selected)} crowns intersecting a 500 m block",
           xlabel="UTM 40N easting (m)", ylabel="UTM 40N northing (m)")
    ax.ticklabel_format(style="plain", useOffset=False)
    fig.text(0.5, 0.01, "Canopy: Meta CHM v2 / CC BY 4.0 · Imagery: Esri World Imagery",
             ha="center", fontsize=8)
    fig.tight_layout(rect=(0, 0.03, 1, 1))
    fig.savefig(path)
    plt.close(fig)
    print(f"Preview block EPSG:32640: {bounds}; {len(selected)} intersecting crowns; {path.stat().st_size} bytes")


def self_test():
    affine = rasterio.Affine(2, 0, 230000, 0, -2, 2710000)
    data = np.array([[3, 4, 0, 0], [5, 10, 0, 0], [0, 0, 0, 0], [0, 0, 0, 7]], dtype="uint8")
    stats = dict(candidateAreaM2=0, retainedAreaM2=0)
    result = list(crowns(data, affine, "EPSG:32640", "test", minimum_area=10, stats=stats))
    assert stats == dict(candidateAreaM2=20, retainedAreaM2=16)
    assert len(result) == 1
    assert result[0]["heightMeters"] == 8.5 and result[0]["minHeightMeters"] == 4.25
    assert result[0]["transmissivity"] == 0.65 and len(result[0]["footprint"]) <= 8
    assert not list(crowns(data, affine, "EPSG:32640", "small"))
    y, x = np.indices((21, 21))
    disk = np.where((x - 10) ** 2 + (y - 10) ** 2 <= 100, 8, 0).astype("uint8")
    assert len(list(crowns(disk, affine, "EPSG:32640", "disk"))[0]["footprint"]) <= 8
    assert not list(crowns(np.full((3, 3), 2, dtype="uint8"), affine, "EPSG:32640", "low"))
    diagonal = np.zeros((4, 4), dtype="uint8")
    diagonal[:2, :2] = 5
    diagonal[2:, 2:] = 7
    assert len(list(crowns(diagonal, affine, "EPSG:32640", "diagonal", minimum_area=10))) == 2
    rows = np.zeros((50, 50), dtype="uint8")
    rows[:4, :] = rows[10:14, :] = rows[:, :4] = 8
    row_stats = dict(candidateAreaM2=0, retainedAreaM2=0)
    split = list(crowns(rows, affine, "EPSG:32640", "rows", stats=row_stats))
    areas = [project(Polygon([(p["longitude"], p["latitude"]) for p in r["footprint"]]),
                     "EPSG:4326", "EPSG:32640").area for r in split]
    assert len(split) > 2 and max(areas) <= CELL_SIZE ** 2 * 1.15
    assert sum(areas) <= row_stats["retainedAreaM2"] * 1.15
    geometry = [{"lon": 54.35, "lat": 24.47}, {"lon": 54.3501, "lat": 24.47}]
    ring = geometry + [{"lon": 54.3501, "lat": 24.4701},
                       {"lon": 54.35, "lat": 24.4701}, geometry[0]]
    cases = [
        ({"highway": "footway", "covered": "arcade"}, geometry, "covered", 2.5, 4, 0),
        ({"highway": "footway", "covered": "colonnade"}, geometry, "covered", 2.5, 4, 0),
        ({"building": "roof", "height": "20 ft", "material": "fabric"}, ring, "canopy", 2.5, 6.10, 0.1),
        ({"man_made": "canopy", "height": "bad"}, ring, "canopy", 2.5, 4, 0),
        ({"amenity": "shelter"}, ring, "shelter", 2, 3, 0),
        ({"bridge": "yes", "width": "12"}, geometry, "bridge", 5, 7, 0),
        ({"bridge": "viaduct"}, geometry, "bridge", 5, 7, 0),
    ]
    for tags, coords, kind, minimum, height, transmission in cases:
        r = structure(dict(type="way", id=1, tags=tags, geometry=coords))
        assert (r["kind"], r["minHeightMeters"], r["heightMeters"], r["transmissivity"]) == (
            kind, minimum, height, transmission)
        polygon = project(Polygon([(p["longitude"], p["latitude"]) for p in r["footprint"]]),
                          "EPSG:4326", "EPSG:32640")
        assert polygon.is_valid and polygon.area > 0
        if kind in ("bridge", "covered"):
            length = project(LineString([(p["lon"], p["lat"]) for p in coords]),
                             "EPSG:4326", "EPSG:32640").length
            width = 3 if kind == "covered" else meters(tags.get("width"), 8)
            assert abs(polygon.area / length - width) < 0.3
    node = structure(dict(type="node", id=2, lon=54.35, lat=24.47, tags={"amenity": "shelter"}))
    polygon = project(Polygon([(p["longitude"], p["latitude"]) for p in node["footprint"]]),
                      "EPSG:4326", "EPSG:32640")
    assert abs(polygon.area - 6) < 0.4
    assert structure(dict(type="way", id=3, tags={"building": "roof"}, geometry=geometry)) is None
    assert meters("NaN", 4) == 4 and meters("-2", 4) == 4 and meters("0", 4) == 4
    print("PASS: tree thresholds, area, 8-connectivity, p90, crown vertex limit, OSM kinds, buffers, units and shelter box")


def main():
    parser = argparse.ArgumentParser(description="Build Abu Dhabi shade data from Meta CHM v2 (CC BY 4.0) and OSM (ODbL).")
    parser.add_argument("--bbox", nargs=4, type=float, default=BBOX, metavar=("WEST", "SOUTH", "EAST", "NORTH"))
    parser.add_argument("--output", type=Path, default=ROOT / "CoolMap/Resources/abudhabi-shade.json")
    parser.add_argument("--cache", type=Path, default=Path("/tmp/coolmap-shade-cache"))
    parser.add_argument("--preview", type=Path)
    parser.add_argument("--preview-only", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    west, south, east, north = args.bbox
    if not (-180 <= west < east <= 180 and -80 < south < north < 84):
        parser.error("bbox must be west,south,east,north")
    cache = args.cache / "_".join(map(str, args.bbox))
    cache.mkdir(parents=True, exist_ok=True)
    if args.preview_only:
        records = json.loads(args.output.read_text())
    else:
        stats = dict(candidateAreaM2=0, retainedAreaM2=0)
        records = list(trees(args.bbox, cache, stats)) + list(structures(args.bbox, cache))
        for index, item in enumerate(records):
            if item["kind"] == "tree":
                item["id"] = f"t{index}"
        records = fit_budget(records, stats)
        payload = json.dumps(records, separators=(",", ":"), allow_nan=False)
        print(json.dumps(dict(minimumCrownAreaM2=MIN_CROWN_AREA, count=len(records),
                              counts=dict(Counter(r["kind"] for r in records)),
                              candidateAreaM2=round(stats["candidateAreaM2"], 2),
                              retainedAreaM2=round(stats["retainedAreaM2"], 2),
                              retainedAreaShare=round(stats["retainedAreaM2"] / stats["candidateAreaM2"], 6)
                              if stats["candidateAreaM2"] else 0,
                              bytes=len(payload.encode()) + 1)), flush=True)
        if len(payload.encode()) + 1 > 10_000_000:
            raise ValueError(f"Output exceeds 10 MB: {len(payload.encode()) + 1} bytes")
        args.output.write_text(payload + "\n")
    counts = Counter(r["kind"] for r in records)
    print(json.dumps(dict(bbox=args.bbox, count=len(records), bytes=args.output.stat().st_size,
                         minimumCrownAreaM2=MIN_CROWN_AREA,
                         counts={kind: counts[kind] for kind in ("tree", "canopy", "covered", "shelter", "bridge")}),
                     sort_keys=True))
    if args.preview:
        preview(records, args.preview, cache)


if __name__ == "__main__":
    main()
