#!/usr/bin/env bash

#  Script to pull all manifest images and search for specific string in $PATH for each gear

GEARS_DIR="$1"
BOUTIQUES_DIR="boutiques"
MANIFESTS_DIR="manifests"

GEAR_SCHEMA_URL="https://raw.githubusercontent.com/flywheel-io/gears/master/spec/manifest.schema.json"
BOUTIQUE_SCHEMA_URL="https://raw.githubusercontent.com/boutiques/boutiques/master/schema/descriptor.schema.json"

GIT_REMOTE=${GIT_REMOTE:-"origin"}
GIT_BRANCH="$( git rev-parse --abbrev-ref HEAD )"
GIT_COMMIT_CURRENT=$( git rev-parse HEAD )


BUILD_ARTIFACTS=""
EXIT_STATUS=0

FSL_GEARS=()

function process_manifests() {
    SKIP=(
      "structural-analysis"
    )
    for manifest_path in $1; do
        echo "manitfest_path ${manifest_path}"
        manifest_type="${manifest_path%%s/*}"
        manifest_name="${manifest_path#*/}"
        manifest_name="${manifest_name%.json}"
        manifest_hier="/$manifest_name"
        manifest_hier="${manifest_hier%/*}"
        manifest_slug="${manifest_name//\//-}"
        >&2 echo "Processing manifest $manifest_type $manifest_name"


        gear_name="$( jq -r '.name' $manifest_path )"
	to_skip=""
	for skip_name in $SKIP; do
	    if [ "$gear_name" == "$skip_name" ]; then
	        echo "Skipping $gear_name"
		to_skip="yes"
	        break
	    fi
	done
	if [ "$to_skip" == "yes" ]; then
	    continue
	fi
        docker_image="$( jq -r '.custom."gear-builder".image' $manifest_path )"
        if [ "$docker_image" == 'null' ]; then
            docker_image="$( jq -r '.custom."docker-image"' $manifest_path )"
        fi
        echo "docker image name"
        echo $docker_image
        ENV_LIST=$(docker run --rm --entrypoint=printenv $docker_image)  
        if echo $ENV_LIST | grep ".*FSL."; then
            echo "Found FSL gear ${manifest_name}"
            # store the docker image or manifest path to a list
            FSL_GEARS+=($manifest_name)
        fi
    done
}

set -eu
manifests=$( find $GEARS_DIR -iname "*.json" )
>&2 echo ${#manifests}

process_manifests "$manifests"

# export the list as an output FSL_GEARS 
echo $FSL_GEARS
printf "%s\n" "${FSL_GEARS[@]}" > FSL_GEARS_LIST.txt



exit $EXIT_STATUS
