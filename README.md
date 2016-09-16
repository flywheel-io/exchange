
Disable concurrent execution of Travis builds

Upon each commit to master:
- retrieve git hash of latest successfully-processed commit
- for each updated weakly-versioned manifest
    - convert to strongly-versioned manifest
    - upload build artifact to storage bucket
- commit all new strongly-versioned manifests
- if commit succeeds, update successfully-processed commit hash
- if commit fails, delete build artifacts from storage bucket


```
.travis
/bin
/manifests
    /fsl
    /afq
/versioned-manifests
    /fsl-<sha384-v1>
    /fsl-<sha384-v2>
    /afq-<sha384-v1>
    /afq-<sha384-v2>
```
