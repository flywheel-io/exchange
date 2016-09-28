## Flywheel Exchange

This repository consists of three distinct assets:
- User-generated, weakly-versioned manifests (`manifests`)
- Machine-generated, strongly-versioned manifests (`versioned-manifests`)
- Manifest processing code (`bin`)

The manifest processing code is automatically executed by Travis whenever a new commit gets pushed. It validates weakly-versioned manifests and converts them to strongly-versioned manifests and rootfs build artifacts.

#### Operation

For each new commit to the master branch:
- Retrieve git hash of latest *successfully-processed commit*
- For each updated weakly-versioned manifest
    - Validate the weakly-versioned manifest against the manifest schema
    - Generate a strongly-versioned rootfs build artifact
    - Upload build artifact to storage bucket
    - Derive a strongly-versioned manifest that references the uploaded build artifact
- Commit all new strongly-versioned manifests
- Update *successfully-processed commit* hash
- Push all commits to GitHub
- If push fails, delete build artifacts from storage bucket

For each new commit to the master branch:
- Validate all weakly-versioned manifests against the manifest schema


#### Notes

Generate Travis-compliant GCP service account string:
```
printf "%q" "$( <flywheel-exchange-storage-service-account.json )"
```
