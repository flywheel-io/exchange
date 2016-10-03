#!/usr/bin/env bash


if ! $( git status &> /dev/null ); then
    echo "This script must be run from within a git repo."
    exit 1
fi
if ! $( git diff-index --quiet HEAD -- ); then
    echo "This script can only be run in a clean git repo."
    exit 1
fi
if [ -z "$EXCHANGE_BUCKET_URI" -o -z "$EXCHANGE_DOWNLOAD_URL" ]; then
    echo "EXCHANGE_BUCKET_URI and EXCHANGE_DOWNLOAD_URL must be defined."
    exit 1
fi

set -eu


MANIFESTS_DIR="manifests"
V_MANIFESTS_DIR="versioned-manifests"
SENTINEL_FILENAME=".sentinel"

GIT_REMOTE=${GIT_REMOTE:-"origin"}
GIT_BRANCH="$( git rev-parse --abbrev-ref HEAD )"
GIT_COMMIT_CURRENT=$( git rev-parse HEAD )
GIT_COMMIT_SENTINEL=$( cat $SENTINEL_FILENAME 2> /dev/null || true )

INVOCATION_SCHEMA=""
BUILD_ARTIFACTS=""
EXIT_STATUS=0


if ! $( git config --get user.email &> /dev/null ); then
    git config user.email "service+github-flywheel-exchange@flywheel.io"
    git config user.name "Flywheel Exchange Bot"
fi

if [ ! -z "$GCLOUD_SERVICE_ACCOUNT" ]; then
    GCLOUD_SERVICE_ACCOUNT_FILE=$( mktemp )
    echo "$GCLOUD_SERVICE_ACCOUNT" > $GCLOUD_SERVICE_ACCOUNT_FILE
    gcloud auth activate-service-account --key-file $GCLOUD_SERVICE_ACCOUNT_FILE
fi


function validate_manifest() {
    # TODO implement manifest validation
    echo "Manifest validation not yet implemented"
}


function validate_manifests() {
    for manifest_path in $1; do
        manifest_name="${manifest_path#*/}"
        manifest_name="${manifest_name%.json}"
        echo "Validating manifest $manifest_name"
        validate_manifest $manifest_path
    done
}


function derive_invocation_schema() {
    # TODO implement invocation schema generation
    echo "Invocation schema generation not yet implemented"
    INVOCATION_SCHEMA=$1
}


cleanup () {
    echo "Restoring git commit history"
    git reset --hard $GIT_COMMIT_CURRENT
    echo "Attempting to remove build artifacts"
    gsutil rm $BUILD_ARTIFACTS
    echo "Build artifacts removed successfully"
}


function process_manifests() {
    for manifest_path in $1; do
        manifest_name="${manifest_path#*/}"
        manifest_name="${manifest_name%.json}"
        manifest_hier="/$manifest_name"
        manifest_hier="${manifest_hier%/*}"
        manifest_slug="${manifest_name//\//-}"
        echo "Processing manifest $manifest_name"

        if ! validate_manifest $manifest_path; then
            EXIT_STATUS=1
            cleanup
        else
            tempdir=$( mktemp -d )
            tempfile=$tempdir/tempfile

            docker_image="$( jq -r '."docker-image"' $manifest_path )"
            container=$( docker create $docker_image /bin/true )
            rootfs_path="$tempdir/$manifest_slug.tgz"
            docker export $container | gzip -n > $rootfs_path
            shasum=$( sha384sum $rootfs_path | cut -d " " -f 1 )

            v_manifest_name="$manifest_slug-sha384-$shasum"
            v_manifest_path="$V_MANIFESTS_DIR/$manifest_hier/$v_manifest_name.json"
            mkdir -p "$V_MANIFESTS_DIR/$manifest_hier"
            cp $manifest_path $v_manifest_path

            jq ".\"git-commit\" = \"$GIT_COMMIT_CURRENT\"" $v_manifest_path \
                > $tempfile && mv $tempfile $v_manifest_path

            jq ".\"rootfs-hash\" = \"sha384:$shasum\" | .\"rootfs-url\" = \"$EXCHANGE_DOWNLOAD_URL/$v_manifest_name.tgz\"" $v_manifest_path \
                > $tempfile && mv $tempfile $v_manifest_path

            derive_invocation_schema $manifest_path # sets $INVOCATION_SCHEMA
            jq ".\"invocation-schema\".\"manifest\" = \"$INVOCATION_SCHEMA\"" $v_manifest_path \
                > $tempfile && mv $tempfile $v_manifest_path

            rootfs_hash_path="$tempdir/$v_manifest_name.tgz"
            mv $rootfs_path $rootfs_hash_path
            gsutil cp $rootfs_hash_path $EXCHANGE_BUCKET_URI
            BUILD_ARTIFACTS="$BUILD_ARTIFACTS $EXCHANGE_BUCKET_URI/${rootfs_hash_path##*/}"

            git add $v_manifest_path
            echo $GIT_COMMIT_CURRENT > $SENTINEL_FILENAME
            git add $SENTINEL_FILENAME
            git commit -m "Process $manifest_name manifest"

            rm -rf $tempdir
        fi
    done

    if git push -q $GIT_REMOTE $GIT_BRANCH; then
        echo "Git push successful"
    else
        echo "Git push failed"
        EXIT_STATUS=1
        cleanup
    fi
}


echo "On branch $GIT_BRANCH"
manifests=$( find $MANIFESTS_DIR -iname "*.json" )
if [ $GIT_BRANCH == "master" ]; then
    if [ ! -z "$GIT_COMMIT_SENTINEL" ]; then
        manifests=$( git diff --name-only $GIT_COMMIT_SENTINEL | grep "^$MANIFESTS_DIR/..*$" || true)
    fi
    if [ -z "$manifests" ]; then
        echo "No updated manifests to process"
    else
        echo "Processing updated manifests"
        echo "$manifests"
        process_manifests "$manifests"
    fi
else
    echo "Validating all manifests"
    validate_manifests "$manifests"
fi

exit $EXIT_STATUS
