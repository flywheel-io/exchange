import sys
from pathlib import Path
import json
from collections import OrderedDict

decoder = json.JSONDecoder(object_pairs_hook=OrderedDict)

UPDATE_STR = """
\t LICENSING NOTE: FSL software are owned by Oxford University Innovation and
license is required for any commercial applications.  For academic use, an
academic license is required which is available by registering on the FSL
website. Any use of the software requires that the user obtain the appropriate
license. See 
[FSL Software Downloads](https://fsl.fmrib.ox.ac.uk/fsldownloads_registration)
for more information.
"""

if __name__ == '__main__':
    gear_list = Path(sys.argv[1])
    root_dir = Path(sys.argv[2])
    gears = []
    with open(gear_list, 'r') as fp:
        gears = [g.strip('\n') for g in fp.readlines()]
    gears = [root_dir / (g + ".json") for g in gears]
    for gear in gears:
        if gear.exists():
            gear_def = OrderedDict()
            with open(gear, 'r') as fp:
                gear_def = json.loads(fp.read(), object_pairs_hook=OrderedDict)
            gear_def['license'] = "Other"
            gear_def['description'] = gear_def.get('description', "") + UPDATE_STR
            with open(gear, 'w') as fp:
                fp.write(json.dumps(gear_def, indent=2))
            print(f"updated: {gear}")



        

