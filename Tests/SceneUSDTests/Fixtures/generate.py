"""Generate an independent, deterministic USDZ fixture with Python's ZIP writer."""
from pathlib import Path
import struct
import zipfile

output = Path(__file__).with_name('reference.usdz')
entries = [
    ('root.usda', b'#usda 1.0\n( defaultPrim = "World" )\ndef Xform "World" {}\n'),
    ('textures/pixel.png', bytes.fromhex(
        '89504e470d0a1a0a0000000d4948445200000001000000010804000000b51c0c02'
        '0000000b4944415478da6364f80f00010501012718e3660000000049454e44ae426082')),
]
with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_STORED) as archive:
    for name, data in entries:
        info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
        info.external_attr = 0o100644 << 16
        padding = -(archive.fp.tell() + 30 + len(name.encode())) % 64
        if 0 < padding < 4:
            padding += 64
        if padding:
            info.extra = struct.pack('<HH', 0x1986, padding - 4) + bytes(padding - 4)
        archive.writestr(info, data)
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    raw = output.read_bytes()
    for info in archive.infolist():
        name_size, extra_size = struct.unpack_from('<HH', raw, info.header_offset + 26)
        assert (info.header_offset + 30 + name_size + extra_size) % 64 == 0
