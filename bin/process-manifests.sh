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
VERSIONED_MANIFESTS_DIR="versioned-manifests"
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
    for manifest_file in $1; do
        manifest_name="${manifest_file%.json}"
        manifest_path="manifests/$manifest_file"
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
    for manifest_file in $1; do
        manifest_name="${manifest_file%.json}"
        manifest_path="manifests/$manifest_file"
        echo "Processing manifest $manifest_name"

        if ! validate_manifest $manifest_path; then
            EXIT_STATUS=1
            cleanup
        else
            tempdir=$( mktemp -d )
            rootfs_path="$tempdir/$manifest_name.tgz"

            docker_image="$( jq -r '."docker-image"' $manifest_path )"
            container=$( docker create $docker_image /bin/true )
            docker export $container | gzip -n > $rootfs_path
            shasum=$( sha256sum $rootfs_path | cut -d " " -f 1 )

            versioned_manifest_name="$manifest_name-sha256-$shasum"
            versioned_manifest_filename="$versioned_manifest_name.json"
            jq ".\"rootfs-hash\" = \"$shasum\" | .\"rootfs-url\" = \"$EXCHANGE_DOWNLOAD_URL/$versioned_manifest_name.tgz\"" $manifest_path \
                > $VERSIONED_MANIFESTS_DIR/$versioned_manifest_filename

            derive_invocation_schema $manifest_path # sets $INVOCATION_SCHEMA
            jq ".\"invocation-schema\"=\"$INVOCATION_SCHEMA\"" $manifest_path \
                > $VERSIONED_MANIFESTS_DIR/$versioned_manifest_filename

            rootfs_hash_path="/tmp/$versioned_manifest_name.tgz"
            mv $rootfs_path $rootfs_hash_path
            gsutil cp $rootfs_hash_path $EXCHANGE_BUCKET_URI
            BUILD_ARTIFACTS="$BUILD_ARTIFACTS $EXCHANGE_BUCKET_URI/${rootfs_hash_path##*/}"

            commit_message="Process $manifest_name manifest"
            git add $VERSIONED_MANIFESTS_DIR/$versioned_manifest_filename
            git commit -m "$commit_message"

            rm -rf $tempdir
        fi
    done

    echo $( git rev-parse HEAD ) > $SENTINEL_FILENAME
    git add $SENTINEL_FILENAME
    git commit -m "Update sentinel"

    if git push -q $GIT_REMOTE $GIT_BRANCH; then
        echo "Git push successful"
    else
        echo "Git push failed"
        EXIT_STATUS=1
        cleanup
    fi
}


if [ $GIT_BRANCH == "master" ]; then
    if [ -z "$GIT_COMMIT_SENTINEL" ]; then
        updated_manifests=$( ls $MANIFESTS_DIR )
    else
        updated_manifests=$( git diff --name-only $GIT_COMMIT_SENTINEL | grep "^$MANIFESTS_DIR/..*$" || true)
    fi
    if [ -z "$updated_manifests" ]; then
        echo "No updated manifests to process"
    else
        process_manifests "$updated_manifests"
    fi
else
    validate_manifests $( ls $MANIFESTS_DIR )
fi

exit $EXIT_STATUS
