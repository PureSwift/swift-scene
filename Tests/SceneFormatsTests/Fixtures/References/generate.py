"""Generate minimal keyed archives from our own reference scene, without tutorial assets."""
from pathlib import Path
import shutil
import math
import plistlib
import struct

root = Path(__file__).parent
(root / 'assets/textures').mkdir(parents=True, exist_ok=True)
uid = plistlib.UID

def write(path, value):
    path.write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=False))

def archive(references):
    objects = ['$null', {'$classname': 'SCNScene'}, {'$classname': 'SCNNode'},
               {'$classname': 'SCNReferenceNode'}, {'$classname': 'NSURL'}]
    def add(value):
        objects.append(value)
        return uid(len(objects) - 1)
    children = []
    for name, path, position in references:
        base = add({'$class': uid(4), 'NS.base': uid(0), 'NS.relative': 'file:///'}) if name == 'nested' else uid(0)
        url = add({'$class': uid(4), 'NS.base': base, 'NS.relative': path})
        children.append(add({'$class': uid(3), 'name': name, 'referenceURL': url,
                             'position': struct.pack('<3f', *position), 'overrides': uid(0)}))
    node = add({'$class': uid(2), 'childNodes': children})
    scene = add({'$class': uid(1), 'rootNode': node})
    return {'$archiver': 'NSKeyedArchiver', '$version': 100000, '$objects': objects, '$top': {'root': scene}}

write(root / 'root.scn', archive([('left', 'models/branch.scn', (5, 0, 0)), ('right', 'models/./branch.scn', (-5, 0, 0))]))
write(root / 'models/branch.scn', archive([('nested', '../assets/leaf.scn', (0, 10, 0))]))
leaf = plistlib.loads((root.parent / 'reference.scn').read_bytes())
objects = leaf['$objects']
# Older NSData archives use NS.data, unlike modern NS.bytes or raw data values.
for obj in objects[:]:
    if not isinstance(obj, dict):
        continue
    for key in ['data', 'elementData']:
        if key not in obj:
            continue
        value = obj[key]
        if isinstance(value, uid):
            value = objects[value.data]
        if isinstance(value, dict):
            value = value.get('NS.bytes', value.get('NS.data'))
        if isinstance(value, bytes):
            obj[key] = uid(len(objects))
            objects.append({'NS.data': value})
    name = obj.get('name')
    if isinstance(name, uid):
        name = objects[name.data]
    if name == 'triangle':
        obj.pop('orientation', None)
        obj['rotation'] = struct.pack('<4f', 0, 0, 1, math.pi / 2)
for obj in objects:
    if isinstance(obj, dict) and 'diffuse' in obj:
        prop = objects[obj['diffuse'].data]
        prop['color'] = uid(0)
        prop['image'] = {'NS.keys': ['path'], 'NS.objects': ['textures/red.jpg']}
write(root / 'assets/leaf.scn', leaf)
shutil.copy(root.parent / 'red.jpg', root / 'assets/textures/red.jpg')
