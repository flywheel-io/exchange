## Flywheel Exchange

This repository consists of three distinct assets:
- User-generated, weakly-versioned *boutiques* and *gears*
- Machine-generated, strongly-versioned *manifests*
- Manifest processing code

The manifest processing code is automatically executed by CircleCI whenever a new commit gets pushed. It validates weakly-versioned *boutiques* and *gears* and converts them to strongly-versioned *manifests* and *rootfs* build artifacts.

#### Operation

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
