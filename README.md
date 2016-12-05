## Flywheel Exchange

This repository consists of three distinct assets:

- User-generated, weakly-versioned *boutiques* and *gears*
- Machine-generated, strongly-versioned *manifests*
- Manifest processing code

The manifest processing code is automatically executed by CircleCI whenever a new commit gets pushed. It validates weakly-versioned *boutiques* and *gears* and converts them to strongly-versioned *manifests* and *rootfs* build artifacts.

#### Operation

![Exchange Operation](http://g.gravizo.com/g?
    digraph G {
        gear_schema [label="Gear Schema"];
        gear_json [label="Gear Spec"];
        boutique_schema [label="Boutique Schema"];
        boutique_json [label="Boutique Spec"];
        manifest [label="Manifest with embedded Invocation Schema"];
        invocation [label="Invocation"];
        boutique_schema -> boutique_json [label="validate"];
        boutique_json -> manifest [label="generate"];
        gear_schema -> gear_json [label="validate"];
        gear_json -> manifest [label="generate"];
        manifest -> invocation [label="validate"];
    }
)

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

#### Notes
```
ORG=[flyhweel|scitran]; REPO=repo; curl -s https://raw.githubusercontent.com/$ORG-apps/$REPO/master/manifest.json | jq --indent 4 ".custom.\"docker-image\"=\"$ORG/$REPO\"" > gears/$ORG/$REPO.json; git add gears; git commit -m "Add $REPO gear"; git show
```
