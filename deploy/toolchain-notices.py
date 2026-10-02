"""Retain original notice paths before removing large expanded installers."""
from pathlib import Path
import re
import shutil

NOTICE = re.compile(r'^(authors|unlicense|licen[cs]e|copying|copyright|notice)([._-].*)?$', re.I)


def retain(source, destination):
    source, destination = Path(source), Path(destination)
    count = 0
    for path in source.rglob('*'):
        if path.is_file() and (NOTICE.match(path.name) or
                any(p.lower() in {'licenses', 'licences'} for p in path.relative_to(source).parts)):
            target = destination / path.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            # Follow a notice symlink while the verified installer is intact;
            # retain independent bytes, never a link into deleted build material.
            target.write_bytes(path.read_bytes())
            count += 1
    if count == 0:
        raise ValueError('Toolchain notices missing; expanded installer retained')
    shutil.rmtree(source)
    return count
