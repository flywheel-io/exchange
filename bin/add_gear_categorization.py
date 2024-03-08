#!/usr/bin/env python
"""Add gear categorization to the different gears.

This script adds the gear categorization from a CSV file to the different gears in the file.
It adds it first to the manifest file and makes a commit to the gear repository, storing a list
of files that have been modified. Then, it goes through the list of modified gears, takes the
new manifest from the gear repository and modifies the corresponding manifest in the gear
exchange repo in GitHub. It finally makes a commit to the gear exchange repository with all
the changes
"""

import csv
import json
import logging
import os
import sys
from argparse import ArgumentParser
from glob import glob
from shutil import rmtree
from typing import List, Optional

import utils

GEAR_EXCHANGE_REPO = "https://gitlab.com/flywheel-io/scientific-solutions/gears/gear-exchange"
NEW_BRANCH_NAME = "GEAR-5440-populate-gear-manifest-with-categorization"

log = logging.getLogger(__name__)
logging.getLogger().addHandler(logging.StreamHandler(sys.stdout))


def update_manifest_single_csv_row(
        this_row: List[str],
        header: List[str],
        new_branch_name: str = NEW_BRANCH_NAME,
) -> Optional[utils.GearDetails]:
    """Update the manifest for a single gear from a row in the CSV file.

    Args:
        this_row (List[str]): Row from the CSV file.
        header (List[str]): Header of the CSV file.
        new_branch_name (str): Name of the new branch to be created.

    Returns:
        Optional[utils.GearDetails]: Gear details if the gear was processed, None otherwise.
    """
    gear_name = this_row[header.index("name")]
    # get the manifest file and the URL of the repo for the gear:
    row_manifest_url, repo_url = utils.get_manifest_url_and_repo_url(this_row, header)
    if not row_manifest_url:
        log.warning("Could not find manifest file for gear: %s", gear_name)
        return None
    log.info("Processing gear: %s", gear_name)

    this_gear_categories = utils.extract_gear_categories(this_row, header)

    gear_repo = utils.clone_repo(repo_url)
    log.debug("local repo path: %s", gear_repo.working_tree_dir)

    utils.update_manifest(gear_repo, this_gear_categories, repo_url)

    changes_to_repo = utils.commit_and_push_changes_to_manifest(
        gear_repo,
        new_branch_name=new_branch_name,
        commit_message="UP: add gear categories to manifest.json"
    )

    if changes_to_repo:
        utils.merge_project(
            repo_url,
            source_branch=new_branch_name,
            target_branch="main" if "gitlab" in repo_url.removeprefix("https://") else "master",
            title=new_branch_name
        )

    # recursively delete the temp file with the local repo:
    rmtree(os.path.dirname(gear_repo.working_tree_dir))

    return utils.GearDetails(gear_name, row_manifest_url)


def update_manifest_in_gear_repos(
        csv_file_path: os.PathLike,
        new_branch_name: str = NEW_BRANCH_NAME,
) -> List[utils.GearDetails]:
    """Update the manifest file in the gear repositories with info from csv file.

    Args:
        csv_file_path (os.PathLike): Path to the CSV file with the gear categorization.
        new_branch_name (str): Name of the new branch to be created.

    Returns:
        list[utils.GearDetails]: List of gears that have been processed.
    """

    with open(csv_file_path, newline='', mode='r', encoding='utf-8-sig') as csvfile:
        csvreader = csv.reader(csvfile)
        # first row is the header line:
        header = next(csvreader)
        # check if the header contains all the categories:
        if any([category not in header for category in utils.CATEGORIES_DICT]):
            log.warning(f"Header does not contain all categories: {utils.CATEGORIES_DICT.keys()}")

        processed_gears = []
        # iterate over the gears in the file:
        for row in csvreader:
            # if gear is tagged to be deprecated, skip it:
            if row[header.index("recom. action")] == "DEP":
                log.debug("Skipping deprecated gear: %s", row[header.index("name")])
                continue

            # if everything went well, add the gear to the list of processed gears:
            # (we store the repo_url so that we don't need to search for it later)
            this_gear = update_manifest_single_csv_row(row, header, new_branch_name)
            if this_gear:
                log.info("Done processing gear: %s", this_gear.gear_name)
                processed_gears.append(this_gear)
            else:
                log.warning("Could not process gear: %s", row[header.index("name")])

    return processed_gears


def find_matching_manifest_files_in_repo(
        gear_to_match: utils.GearDetails,
        exchange_repo: utils.Repo,
) -> Optional[str]:
    """Find manifests with the same gear_name in local repo.

    Manifests can be in different folders if there are custom versions of the gear besides
    the official flywheel one. If so, we'll try to find the one in the folder that matches
    the root of the gear image (Docker image).

    Args:
        gear_to_match (utils.GearDetails): Gear to match.
        exchange_repo (utils.Repo): Repository with the manifests.

    Returns:
        Optional[str]: Absolute path to the matching manifest file.
    """
    matching_manifests = glob(
        os.path.join(
            exchange_repo.working_tree_dir, "gears", "*", f"{gear_to_match.gear_name}.json"
        )
    )
    if not matching_manifests:
        log.warning("Could not find manifest file for gear: %s", gear_to_match.gear_name)
        return None

    if len(matching_manifests) == 1:
        return matching_manifests[0]

    # More than one manifest with the same name found, in different folders.

    # Check first to see if we can find one in the folder with name of the gear image root.
    # Let's get the actual gear manifest from the (remote) gear repo:
    manifest_content = utils.get_manifest_content_from_remote(gear_to_match.repo_manifest_url)
    docker_image = manifest_content.get("custom", {}).get("gear-builder", {}).get("image", "")
    docker_image_root = docker_image.split("/")[0]

    # We'll try in the folder with the same root as the gear image (Docker image):
    for manifest in matching_manifests:
        if os.path.basename(os.path.dirname(manifest)) == docker_image_root:
            return manifest

    # We didn't find one. Give a warning
    log.warning("Could not find a matching manifest for gear: %s", gear_to_match.gear_name)
    log.warning("Matching manifests: %s", matching_manifests)


def update_exchange_manifests(
        gear_list: List[utils.GearDetails],
        new_branch_name: str = NEW_BRANCH_NAME,
) -> None:
    """Update the different manifests in the gear exchange repository.

    Args.
        gear_list (List[utils.GearDetails]): List of gears details that have been processed.
        new_branch_name (str): Name of the new branch to be created in the gear exchange repo.
    """
    # clone the gear exchange repo
    exchange_repo = utils.clone_repo(GEAR_EXCHANGE_REPO)

    # iterate over the processed gear list: grab the manifest from the gear repo and update
    # the corresponding manifest in the gear exchange:
    for gear in gear_list:
        if not gear.repo_manifest_url:
            log.warning("Could not find manifest file for gear: %s", gear.gear_name)
            continue

        if not (target_manifest := find_matching_manifest_files_in_repo(gear, exchange_repo)):
            # Skip this gear. The function find_matching_manifest_files_in_repo will log a warning
            continue

        # we have a target_manifest. Update it with the content of the manifest from the gear repo:
        with open(target_manifest, 'w') as file:
            manifest_content = utils.get_manifest_content_from_remote(gear.repo_manifest_url)
            json.dump(manifest_content, file, indent=2)

    # Now, commit the changes (in a single commit) to the gear exchange repo and push them to the remote
    exchange_repo_changed = utils.commit_manifest_changes_to_gear_exchange_repo(
        exchange_repo,
        new_branch_name=new_branch_name,
        commit_message="UP: update manifests with gear categorization",
    )

    if exchange_repo_changed:
        # create a pull request in the gear exchange repo
        utils.merge_project(
            GEAR_EXCHANGE_REPO,
            source_branch=new_branch_name,
            target_branch="main" if "gitlab" in GEAR_EXCHANGE_REPO.removeprefix("https://") else "master",
            title=new_branch_name
        )

    # recursively delete the temp file with the local repo:
    rmtree(os.path.dirname(exchange_repo.working_tree_dir))


def main(csv_file_path: os.PathLike, new_branch_name: str = NEW_BRANCH_NAME):
    """Main function of the script."""
    logging.basicConfig(level=logging.INFO)
    log.info("Adding gear categorization to gears from CSV file: %s", csv_file_path)
    updated_gears = update_manifest_in_gear_repos(csv_file_path, new_branch_name)
    # if you want to save the list of updated gears to a file, you can do it here:
    utils.save_updated_files_to_csv(updated_gears, "updated_gears.csv")
    update_exchange_manifests(updated_gears)


if __name__ == "__main__":
    parser = ArgumentParser(description="Add gear categorization from CSV file")
    parser.add_argument("--csv", help="CSV file with gear categorization", required=True)
    parser.add_argument("--new_branch_name", help="Name of the new branch to be created", default=NEW_BRANCH_NAME)

    args = parser.parse_args()

    main(args.csv, args.new_branch_name)
