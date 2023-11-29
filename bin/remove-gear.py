#!/usr/bin/env python
"""Remove gear from the exchange"""

import re
import os
from pathlib import Path
import logging
from argparse import ArgumentParser

logging.basicConfig(level=logging.INFO)
log = logging.getLogger()

MANIFEST_ROOT = Path(__file__).parent.parent / "manifests"
GEAR_ROOT = Path(__file__).parent.parent / "gears"


def main(name):

    gear_json = list(GEAR_ROOT.rglob(f'**/{name}.json'))
    if len(gear_json) == 0:
        log.warning("Gear %s not found in GEAR_ROOT folder", name)
    if len(gear_json) > 0:
        log.info("Removing gear %s", gear_json[0])
        os.remove(gear_json[0])

    manifest_jsons = list(MANIFEST_ROOT.rglob(f'**/*{name}*.json'))
    # Filtering once more using regex in case with have a gear with matching
    # part of the name
    reg = re.compile(f".*-{name}-sha.*")
    manifest_jsons = [p for p in manifest_jsons if reg.match(p.name)]
    if len(manifest_jsons) == 0:
        log.warning("Gear %s not found in MANIFEST_ROOT folder", name)
    elif len(manifest_jsons) > 1:
        for manifest in manifest_jsons:
            log.info("Removing gear %s", manifest)
            os.remove(manifest)


if __name__ == "__main__":

    parser = ArgumentParser(description="Remove gear from the exchange")
    parser.add_argument("gear", help="Gear name")

    args = parser.parse_args()

    main(args.gear)
