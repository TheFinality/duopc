"""Checks a signed Mach-O the way iOS does page by page: every code page's SHA-256 against the
CodeDirectory, plus the executable-segment fields. Prints the first bad pages, exits 1 if any.

Usage: check_code_pages.py path/to/Executable
"""
import hashlib
import struct
import sys

LC_SEGMENT_64, LC_CODE_SIGNATURE = 0x19, 0x1D
CSMAGIC_CODEDIRECTORY = 0xFADE0C02


def main(path):
    data = open(path, "rb").read()
    magic, _, _, filetype, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
    assert magic == 0xFEEDFACF, f"not a thin 64-bit Mach-O (magic {magic:#x})"
    offset, sig, text = 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == LC_CODE_SIGNATURE:
            sig = struct.unpack_from("<II", data, offset + 8)
        elif cmd == LC_SEGMENT_64 and data[offset + 8:offset + 24].rstrip(b"\0") == b"__TEXT":
            text = struct.unpack_from("<QQQQ", data, offset + 24)   # vmaddr, vmsize, fileoff, filesize
        offset += size
    if sig is None:
        print("no LC_CODE_SIGNATURE: unsigned")
        return 1
    dataoff, datasize = sig
    superblob = data[dataoff:dataoff + datasize]
    _, _, count = struct.unpack_from(">III", superblob, 0)
    bad_total = 0
    for i in range(count):
        slot, blob_offset = struct.unpack_from(">II", superblob, 12 + 8 * i)
        blob = superblob[blob_offset:]
        if struct.unpack_from(">I", blob, 0)[0] != CSMAGIC_CODEDIRECTORY:
            continue
        version, flags, hash_offset, _, _, n_code, code_limit = struct.unpack_from(">IIIIIII", blob, 8)
        hash_size, hash_type, _, page_log2 = struct.unpack_from(">BBBB", blob, 36)
        exec_seg = struct.unpack_from(">QQQ", blob, 64) if version >= 0x20400 else None
        page = 1 << page_log2
        name = {1: "sha1", 2: "sha256"}.get(hash_type, f"type{hash_type}")
        print(f"CodeDirectory slot {slot:#x}: version {version:#x}, flags {flags:#x}, {name}, page {page}, "
              f"codeLimit {code_limit:#x}, {n_code} code slots (need {-(-code_limit // page)})")
        if exec_seg:
            print(f"  execSeg base {exec_seg[0]:#x} limit {exec_seg[1]:#x} flags {exec_seg[2]:#x}"
                  f"   (__TEXT fileoff {text[2]:#x} filesize {text[3]:#x} vmsize {text[1]:#x})")
        bad = []
        for n in range(n_code):
            want = blob[hash_offset + n * hash_size:hash_offset + (n + 1) * hash_size]
            chunk = data[n * page:min((n + 1) * page, code_limit)]
            got = (hashlib.sha1 if hash_type == 1 else hashlib.sha256)(chunk).digest()[:hash_size]
            if got != want:
                bad.append(n)
        bad_total += len(bad)
        print(f"  {len(bad)} bad page(s)" + (f": first {[hex(n * page) for n in bad[:12]]}" if bad else ""))
    return 1 if bad_total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
