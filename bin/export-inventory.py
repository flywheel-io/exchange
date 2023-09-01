#!/usr/bin/env python3
"""Export a CSV file with the inventory of all gears in the exchange."""
import json
import csv
import logging

from pathlib import Path
from datetime import datetime
from box import Box
import pandas as pd

logging.basicConfig(level=logging.INFO)
log = logging.getLogger()


SUB_FOLDERS = [
    "flywheel",
    "intermountainneuroimaging",
    "pennbbl",
    "scitran",
    "stanfordcni",
    "vistalab",
    "vpnl"
]


def is_api_key_enabled(manifest):
    inputs = manifest.get('inputs', {})
    for k, v in inputs.items():
        if v.get('base', '') == 'api-key':
            return True
    return False


def get_api_key_perm(manifest):
    inputs = manifest.get('inputs', {})
    for k, v in inputs.items():
        if v.get('base', '') == 'api-key':
            if "read-only" in v.keys():
                return 'ro'
            else:
                return 'rw'
    return "N/A"


COL_JSON_MAP = {
    "name": lambda manifest: manifest.get("name"),
    "label": lambda manifest: manifest.get("label"),
    "version": lambda manifest: manifest.get("version"),
    "category": lambda manifest: manifest.get("custom.gear-builder.category"),
    "image": lambda manifest: manifest.get("custom.gear-builder.image"),
    "api_key": lambda manifest: is_api_key_enabled(manifest),
    "key_perm": lambda manifest: get_api_key_perm(manifest),
    "license": lambda manifest: manifest.get("license"),
    "author": lambda manifest: manifest.get("author"),
    "maintainer": lambda manifest: manifest.get("maintainer"),
    "source": lambda manifest: manifest.get("source"),
    "url": lambda manifest: manifest.get("url"),
}


def extract_data_from_manifest_json(file_path):
    with open(file_path, 'r') as f:
        manifest = Box(json.load(f), box_dots=True)
        return [fn(manifest) for fn in COL_JSON_MAP.values()]


def main():
    root_dir = Path('..').absolute() / "gears"
    output_csv = f'exchange-inventory-{datetime.now().date().isoformat()}.csv'

    df = pd.DataFrame(columns=list(COL_JSON_MAP.keys()))
    for folder in SUB_FOLDERS:
        folder_dir = root_dir / folder
        for file_path in folder_dir.rglob("*.json"):
            df.loc[len(df)] = extract_data_from_manifest_json(file_path)
    df.sort_values(by=['name', 'version'], inplace=True)
    df.to_csv(output_csv, index=False)
    log.info(f"Inventory saved to {output_csv}")


if __name__ == "__main__":
    main()
