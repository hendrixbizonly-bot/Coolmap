"""Import real OSM building ways. Unknown heights remain null. No invented patches."""
import sys,json,re,xml.etree.ElementTree as ET
from pathlib import Path
root=ET.parse(sys.argv[1]).getroot()
nodes={n.get('id'):{'latitude':float(n.get('lat')),'longitude':float(n.get('lon'))} for n in root.findall('node')}
records=[]
for way in root.findall('way'):
    tags={t.get('k'):t.get('v') for t in way.findall('tag')}
    if 'building' not in tags: continue
    refs=[n.get('ref') for n in way.findall('nd')]
    if len(refs)<4 or refs[0]!=refs[-1] or any(r not in nodes for r in refs): continue
    height=None; source=None
    match=re.fullmatch(r'\s*(\d+(?:\.\d+)?)\s*(m|ft|meters|metres)?\s*',tags.get('height',''))
    if match:
        height=float(match[1])*(0.3048 if match[2]=='ft' else 1);source='exact'
    elif re.fullmatch(r'\d+(?:\.\d+)?',tags.get('building:levels','')):
        height=float(tags['building:levels'])*3.2;source='levelsEstimate'
    records.append(dict(id='osm-way-'+way.get('id'),footprint=[nodes[r] for r in refs[:-1]],heightMeters=height,heightSource=source,name=tags.get('name:en',tags.get('name'))))
Path(sys.argv[2]).write_text(json.dumps(records,indent=2))
print(f'{len(records)} footprints; {sum(r["heightMeters"] is not None for r in records)} with heights; {sum(r["heightMeters"] is None for r in records)} unknown')
