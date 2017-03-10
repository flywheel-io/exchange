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

if ! $( git config --get user.email &> /dev/null ); then
    git config user.email "service+github-flywheel-exchange@flywheel.io"
    git config user.name "Flywheel Exchange Bot"
fi

if [ ! -z "$GCLOUD_SERVICE_ACCOUNT" ]; then
    GCLOUD_SERVICE_ACCOUNT_FILE=$( mktemp )
    echo "$GCLOUD_SERVICE_ACCOUNT" > $GCLOUD_SERVICE_ACCOUNT_FILE
    gcloud auth activate-service-account --key-file $GCLOUD_SERVICE_ACCOUNT_FILE
fi

if [ ! -z "$DOCKERHUB_USER" -a ! -z "$DOCKERHUB_PASSWORD" ]; then
    docker login -u "$DOCKERHUB_USER" -p "$DOCKERHUB_PASSWORD" $DOCKERHUB_EMAIL
fi

set -eu


function validate_manifest() {
    if [ "$1" == "gear" ]; then
        # Validate the manifest against the schema
        if [ ! -v GEAR_SCHEMA_PATH ]; then
            >&2 echo "Installing gear schema"
            GEAR_SCHEMA_PATH=$( mktemp )
            curl -s $GEAR_SCHEMA_URL > $GEAR_SCHEMA_PATH
        fi
        python -m jsonschema -i "$2" $GEAR_SCHEMA_PATH

        # Confirm the image is valid.
        docker_image="$( jq -r '.custom."docker-image"' $2 )"

        # Parse docker-image to extract image root and tag
        IFS=':' read -ra _docker_image <<< "${docker_image}"
        PARSE_ERROR=0
        if [[ ${#_docker_image[@]} == 1 ]]; then
          image_root=${docker_image}
          image_tag=
          if [[ ${image_root} == *":"* ]]; then PARSE_ERROR=1; fi
        elif [[ ${#_docker_image[@]} == 2 ]]; then
          image_root=${_docker_image[0]}
          image_tag=${_docker_image[1]}
          if [[ -z $image_tag ]]; then PARSE_ERROR=1; fi
        else
          PARSE_ERROR=1
        fi

        if [[ $PARSE_ERROR == 1 ]]; then
          echo "Unrecognized format: Could not parse ${docker_image}" && exit 1
        fi

        # Curl for the image root and check the response for its existence
        response=$(curl -s -S "https://registry.hub.docker.com/v2/repositories/${image_root}/tags/")
        if [[ ${response} != *"Object not found"* ]]; then
          image_info=$(echo ${response} | jq '."results"[]["name"]' | sort)
        else
          echo "Image: \"${docker_image}\" does not exist" && exit 1
        fi

        # If there is a tag, check the response for its existence
        if [[ -n ${image_tag} && ${image_info} != *"\"${image_tag}\""* ]]; then
          echo "Specified image tag: \"${image_tag}\" does not exist for image \"${image_root}\"" && exit 1
        fi

    elif [ "$1" == "boutique" ]; then
        if [ ! -v BOUTIQUE_SCHEMA_PATH ]; then
            >&2 echo "Installing boutique schema"
            BOUTIQUE_SCHEMA_PATH=$( mktemp )
            curl -s $BOUTIQUE_SCHEMA_URL > $BOUTIQUE_SCHEMA_PATH
            jq "del(.required)" $BOUTIQUE_SCHEMA_PATH > $BOUTIQUE_SCHEMA_PATH- && mv $BOUTIQUE_SCHEMA_PATH- $BOUTIQUE_SCHEMA_PATH # FIXME upgrade to full boutiques and remove this hack
        fi
        python -m jsonschema -i "$2" $BOUTIQUE_SCHEMA_PATH
    else
        >&2 echo "Manifest validation for type \"$1\" not implemented"
        return 1
    fi
}


function validate_manifests() {
    for manifest_path in $1; do
        manifest_type="${manifest_path%%s/*}"
        manifest_name="${manifest_path#*/}"
        manifest_name="${manifest_name%.json}"
        >&2 echo "Validating $manifest_type $manifest_name"
        validate_manifest $manifest_type $manifest_path
    done
}


function derive_invocation_schema() {
    if [ "$1" == "gear" ]; then
        echo $( python -m gears generate-invocation-schema "$2" )
    elif [ "$1" == "boutique" ]; then
        # FIXME add invocation schema generation for boutiques
        echo "{\"WARNING\": \"Invocation schema validation for boutiques not yet implemented\"}"
    else
        >&2 echo "Invocation schema generation for type \"$1\" not implemented"
        return 1
    fi
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
        >&2 echo "Processing manifest $manifest_type $manifest_name"

        if ! validate_manifest $manifest_type $manifest_path; then
            >&2 echo "Schema validation failed for $manifest_type $manifest_name"
            EXIT_STATUS=1
            cleanup
        else
            >&2 echo "Schema successfully validated for $manifest_type $manifest_name"

            tempdir=$( mktemp -d )
            tempfile=$tempdir/tempfile

            if [ "$manifest_type" == "gear" ]; then
                docker_image="$( jq -r '.custom."docker-image"' $manifest_path )"
            else
                docker_image="$( jq -r '."container-image"."image"' $manifest_path )"
            fi

            container=$( docker create $docker_image /bin/true )
            rootfs_path="$tempdir/$manifest_slug.tgz"
            docker export $container | gzip -n > $rootfs_path
            shasum=$( sha384sum $rootfs_path | cut -d " " -f 1 )

            v_manifest_name="$manifest_slug-sha384-$shasum"
            v_manifest_path="$MANIFESTS_DIR/$manifest_hier/$v_manifest_name.json"
            mkdir -p "$MANIFESTS_DIR/$manifest_hier"

            jq "{\"$manifest_type\": .}" $manifest_path > $v_manifest_path

            jq ".exchange.\"git-commit\" = \"$GIT_COMMIT_CURRENT\"" $v_manifest_path \
                > $tempfile && mv $tempfile $v_manifest_path

            jq ".exchange.\"rootfs-hash\" = \"sha384:$shasum\" | .exchange.\"rootfs-url\" = \"$EXCHANGE_DOWNLOAD_URL/$v_manifest_name.tgz\"" $v_manifest_path \
                > $tempfile && mv $tempfile $v_manifest_path

            invocation_schema=$( derive_invocation_schema $manifest_type $manifest_path )
            jq ".\"invocation-schema\" = $invocation_schema" $v_manifest_path \
                > $tempfile && mv $tempfile $v_manifest_path
            >&2 echo "Invocation schema generated for $manifest_type $manifest_name"

            rootfs_hash_path="$tempdir/$v_manifest_name.tgz"
            mv $rootfs_path $rootfs_hash_path
            gsutil cp $rootfs_hash_path $EXCHANGE_BUCKET_URI
            BUILD_ARTIFACTS="$BUILD_ARTIFACTS $EXCHANGE_BUCKET_URI/${rootfs_hash_path##*/}"

            git add $v_manifest_path
            echo $GIT_COMMIT_CURRENT > $SENTINEL_FILENAME
            git add $SENTINEL_FILENAME
            git commit -m "Process $manifest_type $manifest_name"

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
if [ -z "$GIT_COMMIT_SENTINEL" ]; then
    >&2 echo "Using all manifests"
    manifests=$( find $GEARS_DIR $BOUTIQUES_DIR -iname "*.json" )
    >&2 echo "$manifests"
else
    >&2 echo "Using updated manifests"
    manifests=$( git diff --name-only $GIT_COMMIT_SENTINEL | grep -e "^$GEARS_DIR/..*$" -e "^$BOUTIQUES_DIR/..*$" || true)
    >&2 echo "$manifests"
fi
if [ -z "$manifests" ]; then
    >&2 echo "No updated manifests to process"
    exit 0
fi

if [ $GIT_BRANCH == "master" ]; then

    >&2 echo "Processing..."
    if [ -z "$EXCHANGE_BUCKET_URI" -o -z "$EXCHANGE_DOWNLOAD_URL" ]; then
        >&2 echo "EXCHANGE_BUCKET_URI and EXCHANGE_DOWNLOAD_URL must be defined."
        exit 1
    fi
    process_manifests "$manifests"
else
    >&2 echo "Validating..."
    validate_manifests "$manifests"
fi

exit $EXIT_STATUS
