"""Fingerprint a local bundle's contents, modes, and symlink targets."""

import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def bundle_digest(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError("expected a real bundle directory")
    root = root.resolve(strict=True)
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            value = os.readlink(path)
            if os.path.isabs(value):
                raise ValueError("absolute symlink in bundle")
            path.resolve(strict=True).relative_to(root)
        elif stat.S_ISREG(mode):
            with path.open("rb") as handle:
                file_hash = hashlib.sha256()
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    file_hash.update(chunk)
                value = file_hash.hexdigest()
        elif stat.S_ISDIR(mode):
            value = None
        else:
            raise ValueError("unexpected special file in bundle")
        entry = [str(path.relative_to(root)), mode, value]
        digest.update(json.dumps(entry, ensure_ascii=True).encode("ascii") + b"\n")
    return digest.hexdigest()


if __name__ == "__main__":
    print(bundle_digest(Path(sys.argv[1])))
