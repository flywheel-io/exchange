## Flywheel Exchange

This repository consists of three distinct assets:

- User-generated, weakly-versioned *boutiques* and *gears*
- Machine-generated, strongly-versioned *manifests*
- Manifest processing code

Manifest processing code is automatically executed by CircleCI whenever a new commit gets pushed. It validates weakly-versioned *boutiques* and *gears* and converts them to strongly-versioned *manifests* and *rootfs* build artifacts.

### Usage

To add a new gear to the Exchange, or to update an existing one, follow these steps:
- Create a properly-formatted [gear manifest](https://github.com/flywheel-io/gears/tree/master/spec), with a unique version, following the [Flywheel Example Gear](https://github.com/flywheel-io/exchange/blob/master/gears/flywheel/example-gear.json).
- Optionally, publish the gear's source code, e.g., on GitHub.
- Publish a tagged Docker image of the gear, e.g., on Docker Hub.
- Your manifest must reference the Docker image location and tag under `custom.docker-image`.
- Open a pull request against this repo that adds your manifest to `gears/<GitHub org>/<gear-name>`.

### Operation

![Exchange Operation](http://g.gravizo.com/g?digraph%20G%20{%20gear_schema%20[label="Gear%20Schema"];%20gear_json%20[label="Gear%20Spec"];%20boutique_schema%20[label="Boutique%20Schema"];%20boutique_json%20[label="Boutique%20Spec"];%20manifest%20[label="Manifest%20with%20embedded%20Invocation%20Schema"];%20invocation%20[label="Invocation"];%20boutique_schema%20->%20boutique_json%20[label="validate"];%20boutique_json%20->%20manifest%20[label="generate"];%20gear_schema%20->%20gear_json%20[label="validate"];%20gear_json%20->%20manifest%20[label="generate"];%20manifest%20->%20invocation%20[label="validate"];%20})

For each new commit to the master branch:

- Retrieve git hash of latest *successfully-processed commit*
- For each updated weakly-versioned boutique or gear
    - Validate boutique or gear against the respective schema
    - Generate strongly-versioned rootfs build artifact
    - Upload build artifact to storage bucket
    - Derive strongly-versioned manifest that references the uploaded build artifact
- Commit all new strongly-versioned manifests
- Update *successfully-processed commit* hash
- Push all commits to GitHub
- If push fails, delete build artifacts from storage bucket

For each new commit to any non-master branch:
- For each weakly-versioned boutique or gear
    - Validate boutique or gear against the respective schema

### Technical Notes
The following commands are useful for adding a gear from *scitran-apps* or *flywheel-apps* to the Exchange. Only the first line needs to be modified, provided that the gear is hosted in the expected location on Docker Hub.

```
ORG=[flyhweel|scitran]; REPO=repo
curl -s https://raw.githubusercontent.com/$ORG-apps/$REPO/master/manifest.json | jq --indent 4 ".custom.\"docker-image\"=\"$ORG/$REPO\"" > gears/$ORG/$REPO.json
git add gears
git commit -m "Add $REPO gear"
git show
```
