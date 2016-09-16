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


GIT_REMOTE=${GIT_REMOTE:-"origin"}
GIT_COMMIT="$( git rev-parse HEAD )"
GIT_BRANCH="$( git rev-parse --abbrev-ref HEAD )"

MANIFESTS_DIR="manifests"
VERSIONED_MANIFESTS_DIR="versioned-manifests"
SENTINEL_FILENAME="SENTINEL"

INVOCATION_SCHEMA=""
BUILD_ARTIFACTS=""
EXIT_STATUS=0


if ! $( git config --get user.email &> /dev/null ); then
    git config user.email "bot@flywheel.exchange"
    git config user.name "Flywheel Exchange Bot"
fi

if $( gcloud auth list |& grep -q "No credentialed accounts" ); then
    echo $GCLOUD_SERVICE_ACCOUNT > .gcloud-service-account
    gcloud auth activate-service-account --key-file .gcloud-service-account
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
    git reset --hard $GIT_COMMIT
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

    if git push $GIT_REMOTE $GIT_BRANCH; then
        echo "Git push successful, attempting to update sentinel"
        echo $( git rev-parse HEAD ) > /tmp/$SENTINEL_FILENAME
        gsutil -h "Content-Type:text/plain" cp /tmp/$SENTINEL_FILENAME $EXCHANGE_BUCKET_URI
        rm /tmp/$SENTINEL_FILENAME
        echo "Sentinel updated successfully"
    else
        echo "Git push failed"
        EXIT_STATUS=1
        cleanup
    fi
}


if [ $GIT_BRANCH == "master" ]; then
    base_commit=$( gsutil cat $EXCHANGE_BUCKET_URI/$SENTINEL_FILENAME 2> /dev/null || true )
    if [ -z "$base_commit" ]; then
        updated_manifests=$( ls $MANIFESTS_DIR )
    else
        updated_manifests=$( git diff --name-only $base_commit | grep "^$MANIFESTS_DIR/..*$" )
    fi
    process_manifests "$updated_manifests"
else
    validate_manifests $( ls $MANIFESTS_DIR )
fi

exit $EXIT_STATUS
