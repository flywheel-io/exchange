#!/usr/bin/env python3
"""Export a CSV file with the inventory of all gears in the exchange."""
import json
import logging
import typing as t
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


def is_api_key_enabled(manifest: dict) -> bool:
    inputs = manifest.get('inputs', {})
    for k, v in inputs.items():
        if v.get('base', '') == 'api-key':
            return True
    return False


def get_api_key_perm(manifest: dict) -> str:
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


def extract_data_from_manifest_json(file_path: Path) -> list:
    with open(file_path, 'r') as f:
        manifest = Box(json.load(f), box_dots=True)
        return [fn(manifest) for fn in COL_JSON_MAP.values()]


def is_flywheel_maintained(url: str) -> t.Union[bool, None]:
    if url is None:
        return None
    if "github.com/flywheel-apps" in url:
        return True
    if "gitlab.com/flywheel-io" in url:
        return True
    if "github.com/scitran-apps" in url:
        return True
    return False


def needs_migration(url: str) -> bool:
    if "gitlab.com/flywheel-io/scientific-solutions" not in url:
        return True
    return False


def main():
    root_dir = Path('..').absolute() / "gears"
    output_csv = f'exchange-inventory-{datetime.now().date().isoformat()}.csv'

    df = pd.DataFrame(columns=list(COL_JSON_MAP.keys()) + ["modified"])
    for folder in SUB_FOLDERS:
        folder_dir = root_dir / folder
        for file_path in folder_dir.rglob("*.json"):
            # turns out that some gears are defined in multiple subfolders
            # so grabbing the modified date to only keep the most recent
            timestamp = file_path.stat().st_mtime
            modified_date = datetime.fromtimestamp(timestamp)
            manifest_data = extract_data_from_manifest_json(file_path)
            manifest_data.append(modified_date.isoformat())
            df.loc[len(df)] = manifest_data

    # Owned by Flywheel or not
    df["fw_owned"] = df.apply(
        lambda row:
        is_flywheel_maintained(row["source"]) or is_flywheel_maintained(row["url"]),
        axis=1
    )

    # In gitlab.com/flywheel-io/scientific-solutions/gears or not
    df["needs_migration"] = df.apply(
        lambda row:
        needs_migration(row["source"]) and needs_migration(row["url"]),
        axis=1
    ) & df["fw_owned"]

    df.sort_values(by=['name', 'modified'], inplace=True)
    df.drop_duplicates(subset=['name'], keep='last', inplace=True)
    df.to_csv(output_csv, index=False)
    log.info(f"Inventory saved to {output_csv}")


if __name__ == "__main__":
    main()
