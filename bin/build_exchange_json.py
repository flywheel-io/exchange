import sys
import json
from pathlib import Path


def rm_extra_keys(d: dict) -> dict:
    for k in ["config", "inputs", "custom", "flywheel"]:
        d.pop(k, None)
    return d


def rm_nulls(d: dict) -> dict:
    if isinstance(d, dict):
        return {k: rm_nulls(v) for k, v in d.items() if v}
    if isinstance(d, list):
        return [rm_nulls(v) for v in d if v]
    return d


def group_by_and_sort(l: list[dict]) -> list:  # noqa
    l.sort(key=lambda d: d["name"])
    groups = {}
    for d in l:
        groups.setdefault(d.get("name"), []).append(d)

    sorted_l = []
    for g in groups.values():
        sorted_l.append(sorted(g, key=lambda v: v["version"], reverse=True))
    return sorted_l


def main(manifest_dir: str, save_path: str):
    gears = []
    for manifest_path in Path(manifest_dir).rglob("*"):
        if not manifest_path.suffix == ".json":
            continue

        with open(manifest_path, "r") as f:
            manifest = json.load(f)

        gear = manifest["gear"]

        gear = rm_extra_keys(gear)

        gear = rm_nulls(gear)

        gears.append(gear)

    grouped_gears = group_by_and_sort(gears)

    with open(save_path, "w") as f:
        json.dump(grouped_gears, f)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
