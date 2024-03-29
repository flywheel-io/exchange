"""Various tools for bulk updating gears on the exchange."""
import sys
from pathlib import Path
import json
from collections import OrderedDict
import subprocess
import tempfile
import time
import os

decoder = json.JSONDecoder(object_pairs_hook=OrderedDict)

UPDATE_STR = (
 " LICENSING NOTE: FSL software are owned by Oxford University Innovation and "
 "license is required for any commercial applications. For commercial licence "
 "please contact fsl@innovation.ox.ac.uk. For academic use, an academic license "
 "is required which is available by registering on the FSL website. Any use of "
 "the software requires that the user obtain the appropriate license. See "
 "https://fsl.fmrib.ox.ac.uk/fsldownloads_registration for more information."
)

def update_exchange(gears, root):
    gear_jsons = [
        p for p in (root / 'gears').rglob('*') if p.is_file() and p.name.endswith('.json')
    ]
    manifest_jsons = [
        p for p in (root / 'manifests').rglob('*') if p.is_file() and p.name.endswith('.json')
    ]
    gears = [g.split('/')[1] for g in gears]
    current_gears = {}
    for path in gear_jsons:
        org = path.parent.name
        gear_def = OrderedDict()
        with open(path, 'r') as fp:
            gear_def = json.loads(fp.read(), object_pairs_hook=OrderedDict)
        name = gear_def.get('name', '')
        if  name in gears:
            gear_def['license'] = "Other"
            gear_def['description'] = gear_def.get('description', "") + UPDATE_STR
            with open(path, 'w') as fp:
                fp.write(json.dumps(gear_def, indent=2, ensure_ascii=False))
            current_gears[org + '/' + name] = gear_def.get('version')
            print(f"updated: {name}")

    for path in manifest_jsons:
        org = path.parent.name
        gear_def = OrderedDict()
        with open(path, 'r') as fp:
            gear = json.loads(fp.read(), object_pairs_hook=OrderedDict)
        gear_def = gear['gear']
        name = gear_def.get('name', '')
        if  name in gears:
            full_name = org + '/' + name
            if full_name in current_gears and gear_def.get('version') == current_gears.get(full_name):
                path.unlink()
                print(f"Removed {path}")
            else:
                gear_def['license'] = "Other"
                gear_def['description'] = gear_def.get('description', "") + UPDATE_STR
                with open(path, 'w') as fp:
                    fp.write(json.dumps(gear, indent=2, ensure_ascii=False))
                print(f"updated: {name}")


def check_updated(src, name):
    url = src.split('https://')[1]
    domain = url.split('.com')
    if len(domain) != 2:
        return
    if domain[0] not in ['gitlab', 'github']:
        return
    domain, path = domain
    path = path.lstrip('/')
    done = True
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        try:
            res = subprocess.run([
                'git', 'clone', '--depth=1',
                f"git@{domain}.com:{path}", "--branch", "update-fsl-license",
                tmp,
            ], cwd=tmp,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            if res.returncode != 0:
                print(name, f"{domain}/{path}")
                return

        except subprocess.CalledProcessError:
            print(name, f"{domain}/{path}")
            return


def update_gear(src, branchname):
    url = src.split('https://')[1]
    domain = url.split('.com')
    if len(domain) != 2:
        return
    if domain[0] not in ['gitlab', 'github']:
        return
    domain, path = domain
    path = path.lstrip('/')
    with tempfile.TemporaryDirectory() as tmp:
        try:
            tmp = Path(tmp)
            res = subprocess.check_output([
                'git', 'clone', '--depth=1',
                f"git@{domain}.com:{path}", tmp
            ], cwd=tmp)
            res = subprocess.check_output([
                'git', 'checkout', '-B', branchname
            ], cwd=tmp)
            res = subprocess.check_output([
                'git', 'checkout', 'master', '--', str(tmp / 'manifest.json')
            ], cwd=tmp)
            gear_def = OrderedDict()
            if not (tmp  / 'manifest.json').exists():
                print(os.listdir(tmp), 'has no manifest') 
                return
            with open(tmp / 'manifest.json', 'r') as fp:
                gear_def = json.loads(fp.read(), object_pairs_hook=OrderedDict)
            print(gear_def['source'])
            gear_def['license'] = "Other"
            gear_def['description'] = gear_def.get('description', "") + UPDATE_STR
            print(gear_def['source'])
            with open(tmp / 'manifest.json', 'w') as fp:
                fp.write(json.dumps(gear_def, indent=2, ensure_ascii=False))
            res = subprocess.check_output([
                'git', 'add', str(tmp / 'manifest.json')
            ], cwd=tmp)
            res = subprocess.check_output([
                'git', 'commit', '-m', 'Update license and description'
            ], cwd=tmp)
            res = subprocess.check_output([
                'git', 'push', 'origin', branchname, '--force',
                '-o', 'merge_request.create'
            ], cwd=tmp)
        except subprocess.CalledProcessError as exc:
            print(exc)


def update_repos(gears, root_dir, branchname):
    gears = [root_dir / (g + ".json") for g in gears]
    for gear in gears:
        if gear.exists():
            gear_def = OrderedDict()
            with open(gear, 'r') as fp:
                gear_def = json.loads(fp.read(), object_pairs_hook=OrderedDict)
            src = gear_def.get('source')
            name = gear_def.get('name')
            out = update_gear(src, branchname)


def check_gears(gears, root_dir):
    gears = [root_dir / (g + ".json") for g in gears]
    for gear in gears:
        if gear.exists():
            gear_def = OrderedDict()
            with open(gear, 'r') as fp:
                gear_def = json.loads(fp.read(), object_pairs_hook=OrderedDict)
            src = gear_def.get('source')
            name = gear_def.get('name')
            check_updated(src, name)


if __name__ == '__main__':
    gear_list = Path(sys.argv[1])
    root_dir = Path(sys.argv[2])
    with open(gear_list, 'r') as fp:
        gears = [g.strip('\n') for g in fp.readlines()]
    update_exchange(gears, root_dir)
    #update_repos(gears, root_dir, 'update-license')
    #check_gears(gears, root_dir)
