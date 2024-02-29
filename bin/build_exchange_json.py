import json
import sys
from functools import partial
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


def add_path_key(d: dict, fpath: Path) -> dict:
    d["exchange-path"] = str(fpath)
    return d


def add_commit_key(d: dict, hash: str) -> dict:
    d["git-commit"] = hash
    return d


def group_by_and_sort(l: list[dict]) -> list[dict]:  # noqa
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

        # list of functions to apply to gear dict
        # all functions take in and return gear dict
        funcs = [
            rm_extra_keys,
            rm_nulls,
            partial(add_path_key, fpath=manifest_path),
            partial(add_commit_key, hash=manifest["exchange"]["git-commit"]),
        ]

        for func in funcs:
            gear = func(gear)

        gears.append(gear)

    grouped_gears = group_by_and_sort(gears)

    with open(save_path, "w") as f:
        json.dump(grouped_gears, f)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
