#!/usr/bin/env bash

GEARS_DIR="gears"
BOUTIQUES_DIR="boutiques"
MANIFESTS_DIR="manifests"
SENTINEL_FILENAME=".sentinel"

GEAR_SCHEMA_URL="https://raw.githubusercontent.com/flywheel-io/gears/master/spec/manifest.schema.json"
BOUTIQUE_SCHEMA_URL="https://raw.githubusercontent.com/boutiques/boutiques/master/schema/descriptor.schema.json"

GIT_REMOTE=${GIT_REMOTE:-"origin"}
GIT_BRANCH="$( git rev-parse --abbrev-ref HEAD )"
GIT_COMMIT_CURRENT=$( git rev-parse HEAD )
GIT_COMMIT_SENTINEL=$( cat $SENTINEL_FILENAME 2> /dev/null || true )

BUILD_ARTIFACTS=""
EXIT_STATUS=0


if [ $BASH_VERSION \< 4.2 ]; then
    >&2 echo "This script requires bash version 4.2 or greater."
    exit 1
fi

if ! $( git status &> /dev/null ); then
    >&2 echo "This script must be run from within a git repo."
    exit 1
fi
if ! $( git diff-index --quiet HEAD -- ); then
    >&2 echo "This script can only be run in a clean git repo."
    exit 1
fi

if [ -z "$EXCHANGE_BUCKET_URI" -o -z "$EXCHANGE_DOWNLOAD_URL" ]; then
    >&2 echo "EXCHANGE_BUCKET_URI and EXCHANGE_DOWNLOAD_URL must be defined."
    exit 1
fi

if ! $( git config --get user.email &> /dev/null ); then
    git config user.email "service+github-flywheel-exchange@flywheel.io"
    git config user.name "Flywheel Exchange Bot"
fi

if [ ! -z "$GCLOUD_SERVICE_ACCOUNT" ]; then
    GCLOUD_SERVICE_ACCOUNT_FILE=$( mktemp )
    echo "$GCLOUD_SERVICE_ACCOUNT" > $GCLOUD_SERVICE_ACCOUNT_FILE
    gcloud auth activate-service-account --key-file $GCLOUD_SERVICE_ACCOUNT_FILE
fi

set -eu


function validate_manifest() {
    if [ "$1" == "gear" ]; then
        if [ ! -v GEAR_SCHEMA_PATH ]; then
            >&2 echo "Installing gear schema"
            GEAR_SCHEMA_PATH=$( mktemp )
            curl -s $GEAR_SCHEMA_URL > $GEAR_SCHEMA_PATH
            jq ".properties.\"docker-image\".type = \"string\"" $GEAR_SCHEMA_PATH > $GEAR_SCHEMA_PATH- && mv $GEAR_SCHEMA_PATH- $GEAR_SCHEMA_PATH
        fi
        python -m jsonschema -i "$2" $GEAR_SCHEMA_PATH
    elif [ "$1" == "boutique" ]; then
        if [ ! -v BOUTIQUE_SCHEMA_PATH ]; then
            BOUTIQUE_SCHEMA_PATH=$( mktemp )
            curl -o $BOUTIQUE_SCHEMA_PATH $BOUTIQUE_SCHEMA_URL
            jq "del(.required)" $BOUTIQUE_SCHEMA_PATH > $BOUTIQUE_SCHEMA_PATH- && mv $BOUTIQUE_SCHEMA_PATH- $BOUTIQUE_SCHEMA_PATH
        fi
        python -m jsonschema -i "$2" $BOUTIQUE_SCHEMA_PATH
    else
        >&2 echo "Manifest validation for type \"$1\" not implemented"
        return 1
    fi
}


function validate_manifests() {
    for manifest_path in $1; do
        manifest_name="${manifest_path#*/}"
        manifest_name="${manifest_name%.json}"
        >&2 echo "Validating manifest $manifest_name"
        validate_manifest $manifest_path
    done
}


function derive_invocation_schema() {
    # TODO implement invocation schema generation
    >&2 echo "Invocation schema generation not yet implemented"
    echo=$1
}


cleanup () {
    >&2 echo "Restoring git commit history"
    git reset --hard $GIT_COMMIT_CURRENT
    >&2 echo "Attempting to remove build artifacts"
    gsutil rm $BUILD_ARTIFACTS
    >&2 echo "Build artifacts removed successfully"
}


function process_manifests() {
    for manifest_path in $1; do
        manifest_type="${manifest_path%%s/*}"
        manifest_name="${manifest_path#*/}"
        manifest_name="${manifest_name%.json}"
        manifest_hier="/$manifest_name"
        manifest_hier="${manifest_hier%/*}"
        manifest_slug="${manifest_name//\//-}"
        >&2 echo "Processing manifest $manifest_name"

        if ! validate_manifest $manifest_type $manifest_path; then
            >&2 echo "Schema validation failed for $manifest_name"
            EXIT_STATUS=1
            cleanup
        else
            >&2 echo "Schema successfully validated for $manifest_name"

            tempdir=$( mktemp -d )
            tempfile=$tempdir/tempfile

            docker_image="$( jq -r '."docker-image"' $manifest_path )"
            container=$( docker create $docker_image /bin/true )
            rootfs_path="$tempdir/$manifest_slug.tgz"
            docker export $container | gzip -n > $rootfs_path
            shasum=$( sha384sum $rootfs_path | cut -d " " -f 1 )

            v_manifest_name="$manifest_slug-sha384-$shasum"
            v_manifest_path="$MANIFESTS_DIR/$manifest_hier/$v_manifest_name.json"
            mkdir -p "$MANIFESTS_DIR/$manifest_hier"

            jq "{\"$manifest_type\": .}" $manifest_path > $v_manifest_path

            jq ".\"git-commit\" = \"$GIT_COMMIT_CURRENT\"" $v_manifest_path \
                > $tempfile && mv $tempfile $v_manifest_path

            jq ".\"rootfs-hash\" = \"sha384:$shasum\" | .\"rootfs-url\" = \"$EXCHANGE_DOWNLOAD_URL/$v_manifest_name.tgz\"" $v_manifest_path \
                > $tempfile && mv $tempfile $v_manifest_path

            invocation_schema=$( derive_invocation_schema $manifest_path )
            jq ".\"invocation-schema\".\"manifest\" = \"$invocation_schema\"" $v_manifest_path \
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
        >&2 echo "Git push successful"
    else
        >&2 echo "Git push failed"
        EXIT_STATUS=1
        cleanup
    fi
}


>&2 echo "On branch $GIT_BRANCH"
manifests=$( find $GEARS_DIR $BOUTIQUES_DIR -iname "*.json" )
if [ $GIT_BRANCH == "master" ]; then
    if [ ! -z "$GIT_COMMIT_SENTINEL" ]; then
        manifests=$( git diff --name-only $GIT_COMMIT_SENTINEL | grep -e "^$GEARS_DIR/..*$" -e "^$BOUTIQUES_DIR/..*$" || true)
    fi
    if [ -z "$manifests" ]; then
        >&2 echo "No updated manifests to process"
    else
        >&2 echo "Processing updated manifests"
        >&2 echo "$manifests"
        process_manifests "$manifests"
    fi
else
    >&2 echo "Validating all manifests"
    validate_manifests "$manifests"
fi

exit $EXIT_STATUS
