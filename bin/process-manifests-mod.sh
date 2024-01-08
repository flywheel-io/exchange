#!/usr/bin/env bash
#set -eEuo pipefail
set -x  # Enable debugging

GEARS_DIR="gears"
BOUTIQUES_DIR="boutiques"
MANIFESTS_DIR="manifests"
SENTINEL_FILENAME=".sentinel"
EXCHANGE_JSON="exchange.json"

GEAR_SCHEMA_URL="https://raw.githubusercontent.com/flywheel-io/gears/master/spec/manifest.schema.json"
BOUTIQUE_SCHEMA_URL="https://raw.githubusercontent.com/boutiques/boutiques/master/schema/descriptor.schema.json"
EXCHANGE_ARTIFACT_REGISTRY_URL="us-docker.pkg.dev/flywheel-exchange/gear-exchange"

GIT_REMOTE=${GIT_REMOTE:-"origin"}
GIT_BRANCH="$( git rev-parse --abbrev-ref HEAD )"
GIT_COMMIT_CURRENT=$( git rev-parse HEAD )

# GIT_COMMIT_SENTINEL represents the closest ancestor git commit, under
# which a manifest was generated successfully. This is used to determine which
# gears and boutiques have since been changed or added and thus need to be
# processed.
# TODO commenting below and hard coding the commit for testing
# GIT_COMMIT_SENTINEL=$( cat $SENTINEL_FILENAME 2> /dev/null || true )
GIT_COMMIT_SENTINEL="edc20abe2eba9f393e9477d3c2bd315cf8f4ba61"

BUILD_ARTIFACTS=""
EXIT_STATUS=0


git_config_cleanup () {
    git config --local --remove-section user 2>/dev/null || true
}
trap git_config_cleanup EXIT


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
    git config --local user.email $CI_PUSH_USER_EMAIL
    git config --local user.name $CI_PUSH_USER_NAME
fi
#
## TODO
if [ ! -z "$EXCHANGE_SERVICE_ACCOUNT" ]; then
    GCLOUD_SERVICE_ACCOUNT_FILE=$( mktemp )
    # GCLOUD_SERVICE_ACCOUNT MUST be Base-64 Encoded!
    echo "$GCLOUD_SERVICE_ACCOUNT" | base64 -d > $GCLOUD_SERVICE_ACCOUNT_FILE
    gcloud auth activate-service-account --key-file $GCLOUD_SERVICE_ACCOUNT_FILE
fi

if [ ! -z "$DOCKER_CI_USER" -a ! -z "$DOCKER_CI_PASS" ]; then
    echo "$DOCKER_CI_PASS" | docker login -u "$DOCKERHUB_USER" --password-stdin
fi


function gear_version_already_exists() {
    if [ "$#" -ne 3 ]; then
         >&2 echo "Invalid number of positional arguments in gear_version_already_exists()"
        exit 1
    fi

    gear_org="$1"
    gear_name="$2"
    gear_version="$3"

    if [ -d "$MANIFESTS_DIR/$gear_org" ]; then
        for f in "$MANIFESTS_DIR/$gear_org/"*.json ; do
            v_gear_name="$( jq -r '.gear.name' $f )"
            v_gear_version="$( jq -r '.gear.version' $f )"

            if [[ "$gear_name" == "$v_gear_name" && "$gear_version" == "$v_gear_version" ]] ; then
                >&2 echo "Strongly versioned gear '$gear_name' of version '$gear_version' found in file '$f'"

                # true = 0
                return 0
            fi
        done
    fi

    # false = 1
    return 1
}


function validate_manifest() {

    if [[ "$2" != *.json ]]; then
        >&2 echo "Manifest files must have a .json file name extension."
        exit 1
    fi

    if [ "$1" == "gear" ]; then
        # Validate that strongly versioned gear with same name and version doesn't already exist.
        gear_name="$( jq -r '.name' $2 )"
        gear_version="$( jq -r '.version' $2 )"
        gear_dir="${2%/*}"
        gear_org="${gear_dir##*/}"
        if gear_version_already_exists "$gear_org" "$gear_name" "$gear_version" ; then
          >&2 echo "Error: Candidate gear already strongly versioned. Submit the gear to the exchange with a unique version." && exit 1
        fi

        # Validate the manifest against the schema
        if [ ! -v GEAR_SCHEMA_PATH ]; then
            >&2 echo "Installing gear schema"
            GEAR_SCHEMA_PATH=$( mktemp )
            curl -s $GEAR_SCHEMA_URL > $GEAR_SCHEMA_PATH
        fi
        python -m jsonschema -i "$2" $GEAR_SCHEMA_PATH

        # Confirm the image is valid.
        docker_image="$( jq -r '.custom."gear-builder".image' $2 )"
        if [ "$docker_image" == 'null' ]; then
            docker_image="$( jq -r '.custom."docker-image"' $2 )"
        fi

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

        if [[ -z $image_tag ]]; then
          echo "A tagged image is required!" && exit 1
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
    gcloud container images delete --quiet $exchange_image
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
                docker_image="$( jq -r '.custom."gear-builder".image' $manifest_path )"
                if [ "$docker_image" == 'null' ]; then
                    docker_image="$( jq -r '.custom."docker-image"' $manifest_path )"
                fi
                manifest_version="$( jq -r '.version' $manifest_path )"
            else
                docker_image="$( jq -r '."container-image"."image"' $manifest_path )"
                manifest_version=""
            fi
            >&2 echo "Docker image: $docker_image"
            >&2 echo "Manifest version: $manifest_version"

#            beta_exchange="$( jq -r '.custom.flywheel.beta_exchange' $manifest_path)"
#            if [ "$beta_exchange" == "true" ]; then
#                echo "Pulling image $docker_image"
#                docker pull $docker_image
#                # Get docker image digest
#                digest=$(docker inspect $docker_image | jq -r '.[0].RepoDigests[0]')
#                # Strip off just the sha256 hash value
#                sha256=$(printf "$digest" | sed 's/.*\://')
#                v_manifest_name="$manifest_slug-sha256-$sha256"
#                v_manifest_path="$MANIFESTS_DIR/$manifest_hier/$v_manifest_name.json"
#                mkdir -p "$MANIFESTS_DIR/$manifest_hier"
#
#                jq "{\"$manifest_type\": .}" $manifest_path > $v_manifest_path
#
#                jq ".exchange.\"git-commit\" = \"$GIT_COMMIT_CURRENT\"" $v_manifest_path \
#                    > $tempfile && mv $tempfile $v_manifest_path
#
#                jq ".exchange.\"rootfs-hash\" = \"sha256:$sha256\" |
#                    .exchange.\"rootfs-url\" =
#                        \"docker://$EXCHANGE_ARTIFACT_REGISTRY_URL/$manifest_slug@sha256:$sha256\"" $v_manifest_path \
#                    > $tempfile && mv $tempfile $v_manifest_path
#
#                invocation_schema=$( derive_invocation_schema $manifest_type $manifest_path )
#                jq ".\"invocation-schema\" = $invocation_schema" $v_manifest_path \
#                    > $tempfile && mv $tempfile $v_manifest_path
#                >&2 echo "Invocation schema generated for $manifest_type $manifest_name"
#
#                exchange_image="$EXCHANGE_ARTIFACT_REGISTRY_URL/$manifest_slug:$manifest_version"
#                docker tag $docker_image $exchange_image
#                echo $ARTIFACT_REGISTRY_KEY | docker login -u _json_key_base64 \
#                    --password-stdin \
#                    https://us-docker.pkg.dev
#                docker push $exchange_image
#            else
#                container=$( docker create $docker_image /bin/true )
#                rootfs_path="$tempdir/$manifest_slug.tgz"
#                >&2 echo "Exporting container"
#                docker export $container | gzip -n > $rootfs_path
#                shasum=$( sha384sum $rootfs_path | cut -d " " -f 1 )
#                #docker rm $container # fails on CircleCI
#
#                v_manifest_name="$manifest_slug-sha384-$shasum"
#                v_manifest_path="$MANIFESTS_DIR/$manifest_hier/$v_manifest_name.json"
#                mkdir -p "$MANIFESTS_DIR/$manifest_hier"
#
#                jq "{\"$manifest_type\": .}" $manifest_path > $v_manifest_path
#
#                jq ".exchange.\"git-commit\" = \"$GIT_COMMIT_CURRENT\"" $v_manifest_path \
#                    > $tempfile && mv $tempfile $v_manifest_path
#
#                jq ".exchange.\"rootfs-hash\" = \"sha384:$shasum\" | .exchange.\"rootfs-url\" = \"$EXCHANGE_DOWNLOAD_URL/$v_manifest_name.tgz\"" $v_manifest_path \
#                    > $tempfile && mv $tempfile $v_manifest_path
#
#                invocation_schema=$( derive_invocation_schema $manifest_type $manifest_path )
#                jq ".\"invocation-schema\" = $invocation_schema" $v_manifest_path \
#                    > $tempfile && mv $tempfile $v_manifest_path
#                >&2 echo "Invocation schema generated for $manifest_type $manifest_name"
#
#                rootfs_hash_path="$tempdir/$v_manifest_name.tgz"
#                mv $rootfs_path $rootfs_hash_path
#                gsutil cp $rootfs_hash_path $EXCHANGE_BUCKET_URI
#                BUILD_ARTIFACTS="$BUILD_ARTIFACTS $EXCHANGE_BUCKET_URI/${rootfs_hash_path##*/}"
#
#                exchange_image="$GCR_HOST_PROJECT/$manifest_slug:$manifest_version"
#                docker tag $docker_image $exchange_image
#                gcloud docker -- push $exchange_image
#            fi
#
#            git add $v_manifest_path
#            echo $GIT_COMMIT_CURRENT > $SENTINEL_FILENAME
#            git add $SENTINEL_FILENAME
#            git commit -m "Process $manifest_type $manifest_name $manifest_version"
#
#            rm -rf $tempdir
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


publish_global_manifest() {
    >&2 echo "Publish global manifest"
    find manifests -type f | xargs jq -sS '[ .[].gear | del(.config, .inputs, .custom, .flywheel) ] | del(.[] | nulls) | group_by(.name) | .[] |= sort_by(.version) | .[] |= reverse' > .$EXCHANGE_JSON
    git checkout gh-pages-json
    mv -f .$EXCHANGE_JSON $EXCHANGE_JSON
    git add $EXCHANGE_JSON
    git commit --amend --reset-author -m "Add exchange.json"
    git push -f $GIT_REMOTE  gh-pages-json
    git checkout $GIT_BRANCH
}

function get_manifests_list() {
  >&2 echo "On branch $GIT_BRANCH"

  if [ -z "$GIT_COMMIT_SENTINEL" ]; then
    >&2 echo "Using all manifests"
    manifests=$(find "$GEARS_DIR" "$BOUTIQUES_DIR" -iname "*.json")
    >&2 echo "$manifests"
  else
    >&2 echo "Using updated manifests"
    >&2 echo "DEBUG-- GIT_COMMIT_SENTINEL: $GIT_COMMIT_SENTINEL"
    manifests=$(git diff --name-only --diff-filter=d "$GIT_COMMIT_SENTINEL" | grep -e "^$GEARS_DIR/..*$" -e "^$BOUTIQUES_DIR/..*$" || true)
    >&2 echo "$manifests"
  fi

  if [ -z "$manifests" ]; then
    >&2 echo "No manifests to process or validate"
    exit 0
  fi

  export manifests  # Export the manifests variable
  >&2 echo "Exported manifests variable: $manifests"
}

get_manifests_list
>&2 echo "Exported manifests variable: $manifests"
if [ $GIT_BRANCH == "GEAR-2518-exchange-CI-plugin" ]; then
    >&2 echo "Processing..."
    # TODO figure out the exchange stuff
#    if [ -z "$EXCHANGE_BUCKET_URI" -o -z "$EXCHANGE_DOWNLOAD_URL" ]; then
#        >&2 echo "Error: EXCHANGE_BUCKET_URI and EXCHANGE_DOWNLOAD_URL must be defined."
#        exit 1
#    fi
    set -eu
    process_manifests "$manifests"
    publish_global_manifest
else
    >&2 echo "Validating..."
    set -eu
    validate_manifests "$manifests"
fi




exit $EXIT_STATUS



#>&2 echo "On branch $GIT_BRANCH"
#if [ -z "$GIT_COMMIT_SENTINEL" ]; then
#    >&2 echo "Using all manifests"
#    manifests=$( find $GEARS_DIR $BOUTIQUES_DIR -iname "*.json" )
#    >&2 echo "$manifests"
#else
#    >&2 echo "Using updated manifests"
#    echo "GIT_COMMIT_SENTINEL: $GIT_COMMIT_SENTINEL"
#    git diff --name-only --diff-filter=d $GIT_COMMIT_SENTINEL
#    manifests=$( git diff --name-only --diff-filter=d $GIT_COMMIT_SENTINEL | grep -e "^$GEARS_DIR/..*$" -e "^$BOUTIQUES_DIR/..*$" || true )
#    >&2 echo "$manifests"
#fi
#if [ -z "$manifests" ]; then
#    >&2 echo "No manifests to process or validate"
#    exit 0
#fi
#
#if [ $GIT_BRANCH == "master" ]; then
#    >&2 echo "Processing..."
#    if [ -z "$EXCHANGE_BUCKET_URI" -o -z "$EXCHANGE_DOWNLOAD_URL" ]; then
#        >&2 echo "Error: EXCHANGE_BUCKET_URI and EXCHANGE_DOWNLOAD_URL must be defined."
#        exit 1
#    fi
#    set -eu
#    process_manifests "$manifests"
#    publish_global_manifest
#else
#    >&2 echo "Validating..."
#    set -eu
#    validate_manifests "$manifests"
#fi


