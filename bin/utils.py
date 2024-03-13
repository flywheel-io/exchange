import json
import logging
import os
import requests
import tempfile
from collections.abc import Mapping
from copy import deepcopy
from time import sleep
from typing import List, Optional, Tuple
from urllib.parse import urlparse

from dotty_dict import dotty
from git import Repo

# dictionary to map the categories in the CSV file to the categories in the Flywheel manifest:
CATEGORIES_DICT = {
    "category": "custom.gear-builder.category",
    "Species": "custom.flywheel.classification.species",
    "Organ": "custom.flywheel.classification.organ",
    "Therapeutic Area": "custom.flywheel.classification.therapeutic_area",
    "Modality": "custom.flywheel.classification.modality",
    "Function": "custom.flywheel.classification.function",
    "Suite": "custom.flywheel.suite",
    "Gear Permission": "gear_permission",  # <- this one is special, we'll remove before
    #                                           updating manifest
}
# those categories that can have multiple values:
LIST_TYPE_CATEGORIES = [
    "Species",
    "Organ",
    "Therapeutic Area",
    "Modality",
    "Function",
]
# Verify that all categories in LIST_TYPE_CATEGORIES are in CATEGORIES_DICT:
if any([category not in CATEGORIES_DICT for category in LIST_TYPE_CATEGORIES]):
    raise ValueError(
        f"LIST_TYPE_CATEGORIES contains categories not in CATEGORIES_DICT: {LIST_TYPE_CATEGORIES}"
    )


# get the private tokens from the environment:
GITLAB_PRIVATE_TOKEN = os.environ.get('GITLAB_PRIVATE_TOKEN')
if not GITLAB_PRIVATE_TOKEN:
    raise RuntimeError("GITLAB_PRIVATE_TOKEN environment variable not set.")
GITHUB_PRIVATE_TOKEN = os.environ.get('GITHUB_PRIVATE_TOKEN')
if not GITHUB_PRIVATE_TOKEN:
    raise RuntimeError("GITHUB_PRIVATE_TOKEN environment variable not set.")


log = logging.getLogger(__name__)


class GearDetails:
    """Class to hold the details of a gear."""
    def __init__(self, name, url):
        self.gear_name = name
        self.repo_manifest_url = url

    def __str__(self):
        return f"{self.gear_name}, {self.repo_manifest_url}"

    def __repr__(self):
        return f"{self.gear_name}, {self.repo_manifest_url}"


def gitlab_or_github_repo(repo_url: str) -> Optional[str]:
    """Return "gitlab" or "github" if the repo is in GitLab or GitHub or none if it's neither.

    Check the host (we don't just assume that if "gitlab" in string, it is Gitlab, because
    it could be part of the repo name):
    """
    domain = urlparse(repo_url).netloc
    if "gitlab" in domain:
        return "gitlab"
    if "github" in domain:
        return "github"
    return None


def get_manifest_content_from_remote(manifest_url: str) -> Optional[dict]:
    """Retrieve the actual manifest file from the URL of the remote repository.

    Args:
        manifest_url (str): URL of the manifest file.

    Returns:
        Optional[dict]: The content of the manifest file.
    """
    try:
        response = requests.get(manifest_url)
    except requests.exceptions.RequestException as e:
        log.warning("Error getting manifest.json from %s: %s", manifest_url, e)
        return None

    if response.status_code != 200:
        log.debug("Could not download the manifest.json at %s", manifest_url)
        return None

    return response.json()


def get_repo_manifest_url(repo_url: str) -> Optional[str]:
    """Get the manifest url.

    Try to see if there is a valid manifest.json file in the repo. Try "main" and "master"
    branches.

    Args:
        repo_url (str): URL of the repository.

    Returns:
        Optional[str]: URL of the manifest file.
    """
    server_type = gitlab_or_github_repo(repo_url)
    if server_type == "gitlab":
        raw_content_url_base = f"{repo_url}/-/raw"
    elif server_type == "github":
        raw_content_url_base = (
            "https://raw.githubusercontent.com/"
            f"{repo_url.split('github.com/')[1]}"
        )
    else:
        log.warning("Could not determine server type for %s", repo_url)
        return None

    for branch in ["main", "master"]:
        manifest_url = f"{raw_content_url_base}/{branch}/manifest.json"
        manifest_dict = get_manifest_content_from_remote(manifest_url)
        if manifest_dict and (
            manifest_dict.get("custom", {}).get("gear-builder") or
            manifest_dict.get("custom", {}).get("docker-image")
        ):
            log.debug("Found manifest.json in %s", manifest_url)
            return manifest_url

    log.warning("Could not find a gear manifest.json in %s main or master branches", repo_url)
    return None


def get_manifest_url_and_repo_url(
        this_row: List[str], header: List[str],
) -> Tuple[Optional[str], Optional[str]]:
    """Get the manifest file and the URL of the repo for the gear.

    There are two URLs, and sometimes they have been used interchangeably. So find the one that
    contains a "manifest.json" file in it, with preference for repos in GitLab.

    Args:
        this_row (List[str]): the row in the CSV file.
        header (List[str]): the header of the CSV file.

    Returns:
        Optional[str]: the URL of the manifest file if found, None otherwise.
        Optional[str]: the URL of the repo if found, None otherwise.
    """
    url_column_names = ["source", "url"]
    repos = [this_row[header.index(url)] for url in url_column_names]
    # we give preference to Gitlab repos, so we'll check them first:
    gitlab_repo = next((repo for repo in repos if "gitlab" in repo), None)
    if gitlab_repo:
        manifest_url = get_repo_manifest_url(gitlab_repo)
        if manifest_url:
            return manifest_url, gitlab_repo
        # if we didn't find it, remove this repo from the list of repos to process:
        repos.remove(gitlab_repo)
    # if we're here, we haven't found the manifest yet. Try the rest of the repos:
    for repo in repos:
        manifest_url = get_repo_manifest_url(repo)
        if manifest_url:
            return manifest_url, repo
    # if we're here, we haven't found the manifest in any of the repos:
    return None, None


def extract_gear_categories(row: list, header: list) -> dict:
    """Extract the gear categories from the row.

    Use a dotty dictionary to store the categories, so we can set them using dot notation.
    Then, return a regular (nested) dictionary.
    """
    gear_categories = dotty()
    for c, field in CATEGORIES_DICT.items():
        # if this category is one of those that can have multiple values:
        if c in LIST_TYPE_CATEGORIES:
            # split the values by ", " and store them as a list.
            # Then, to make sure we don't have repeated values, convert the list to a set and back to a list:
            gear_categories[field] = list(set(row[header.index(c)].split(", ")))
        else:
            gear_categories[field] = row[header.index(c)]

    return gear_categories.to_dict()


def set_gear_permission(permission: str, current_manifest: dict):
    """Set the gear permission in the manifest."""
    # in case the permission is an empty string:
    if not permission:
        permission = "None"
    # First, check that the permission is valid:
    if permission not in ["None", "Read-only", "Read-write", "Admin"]:
        raise ValueError(f"Invalid gear permission: {permission}")
    # Now, if the permission is "None":
    if permission == "None":
        # check that the "inputs.api-key" is not in the current manifest:
        if current_manifest["inputs"].get("api-key", None):
            raise ValueError(
                "Gear permission should be 'None', but 'inputs.api-key' present in manifest."
            )
        return
    if permission == "Admin":
        raise ValueError("'Admin' gears are not supported at this time.")
    # set "inputs.api-key.read-only" to True if permission is "Read Only", False otherwise:
    current_manifest["inputs"]["api-key"]["read-only"] = permission == "Read Only"


def clone_repo(repo_url) -> Repo:
    """Clone the repo in the given URL.

    We'll do a shallow clone, so we don't need to clone the entire history of the repo.
    We'll use the SSH URL, so we don't need to provide credentials to push the changes.

    Returns:
        Repo: a gitpython Repo object with the cloned repo.
    """
    repo_name = repo_url.split('/')[-1].replace('.git', '')
    # create a temp dir in which to clone the repo:
    cloned_repo_path = os.path.join(tempfile.mkdtemp(prefix="gear_categorization_"), repo_name)
    # check to see if the url is https or ssh (we want ssh):
    if repo_url.startswith("https://"):
        # "https://github.com/foo/bar" -> "git@github.com:foo/bar.git"
        # "https://gitlab.com/foo/bar" -> "git@gitlab.com:foo/bar.git"
        # replace "https://" with "git@", then the first "/" with ":" and attach ".git" at the end:
        repo_url = repo_url.replace("https://", "git@", 1).replace("/", ":", 1)
        if not repo_url.endswith(".git"):
            repo_url += ".git"
    return Repo.clone_from(repo_url, cloned_repo_path, depth=1)


def commit_and_push_changes_to_manifest(
        repo: Repo, new_branch_name="Update_manifest", commit_message="Update manifest.json",
) -> bool:
    """Commit and push the changes to the manifest a new branch.

    Args:
        repo (Repo): the gitpython Repo object for the repository.
        new_branch_name (str): name of the new branch to be created in the repo.
        commit_message (str): commit message for the changes.

    Returns:
        bool: True if there were changes to commit and push, False otherwise.
    """
    new_branch = repo.create_head(new_branch_name)
    new_branch.checkout()
    repo.git.pull()   # in case there are changes in the remote repo
    # make sure we have only changed the manifest:
    repo_changes = [item.a_path for item in repo.index.diff(None)]
    if "manifest.json" not in repo_changes:
        log.warning("No changes to the manifest.json")
        return False

    if repo_changes == ["manifest.json"]:
        repo.index.add(['manifest.json'])
        repo.index.commit(commit_message)
        repo.remotes.origin.push(refspec=f"{new_branch.name}:{new_branch.name}")
        return True

    log.warning("There were changes to files other than manifest.json")
    log.warning("Changes: %s", repo_changes)
    log.warning("Not committing or pushing changes.")
    return False


def deep_merge(dict1, dict2):
    """ Return a new dictionary by merging two dictionaries recursively. """
    result = deepcopy(dict1)
    for key, value in dict2.items():
        if isinstance(value, Mapping):
            result[key] = deep_merge(result.get(key, {}), value)
        else:
            result[key] = deepcopy(dict2[key])
    return result


def update_manifest(repo: Repo, update_info: dict, repo_url: str):
    """Update the Repo manifest file with the update_info, and check gear_url."""
    manifest_path = os.path.join(repo.working_tree_dir, 'manifest.json')
    if os.path.exists(manifest_path):
        with open(manifest_path, 'r+') as file:
            manifest = json.load(file)
            # set the gear permission (and remove it from the update_info):
            gear_permission = update_info.pop("gear_permission", "None")
            set_gear_permission(gear_permission, manifest)
            # set all the other properties:
            try:
                manifest = deep_merge(manifest, update_info)
            except Exception as e:
                log.error(f"Error updating manifest: {manifest_path}")
                raise e
            # check that the gear_url is the same as the repo_url:
            if not manifest.get("url") == repo_url:
                log.warning("Gear URL in manifest.json does not match the repo URL.")
                log.warning("Switching gear URL and source.")
                new_source = manifest.get("source", "")
                manifest["url"] = repo_url
                manifest["source"] = new_source

            # overwrite the manifest file with the updated manifest:
            file.seek(0)
            json.dump(manifest, file, indent=2)
            file.write('\n')  # add a newline at the end of the file
            file.truncate()
    else:
        log.warning(f"Manifest.json not found in {repo.working_tree_dir}")


gitlab_repos = {}
github_repos = {}


def merge_project(
        remote_repo: str,
        source_branch: str,
        target_branch: str,
        title: str = "Update manifest.json",
        automerge: bool = False,
        skip_ci: bool = False,
):
    """Create a merge request in the given project.

    Arguments:
        remote_repo (str): URL of the remote repository.
        source_branch (str): name of the source branch.
        target_branch (str): name of the target branch.
        title (str): title of the merge request.
        automerge (bool): whether to actually merge the MR after creating it.
        skip_ci (bool): whether to skip the CI pipeline.
    """
    description = "Update manifest.json with gear categories"
    if skip_ci:
        description += "\n\n[skip ci]"

    def merge_project_gitlab():
        """Create a merge request in a GitLab project."""
        if not gitlab_repos:
            from gitlab import Gitlab
        # get the Gitlab object for the given URL:
        if host_url not in gitlab_repos:
            gitlab_repos[host_url] = Gitlab(host_url, private_token=GITLAB_PRIVATE_TOKEN)
        gl = gitlab_repos[host_url]

        project = gl.projects.get(repo_path)
        mr = project.mergerequests.create({
            "source_branch": source_branch,
            "target_branch": target_branch,
            "title": title,
            "description": description,
            "remove_source_branch": True,
            "allow_maintainer_to_push": True,
            "approvals_before_merge": 0,
        })
        if automerge:
            # it looks like if you try to merge a MR that is not ready, it will fail.
            sleep(15)
            mr.merge(merge_when_pipeline_succeeds=True)

    def merge_project_github():
        """Create a merge request in a GitHub project."""
        if not github_repos:
            from github import Auth, Github
        # get the GitHub object for the given URL:
        if host_url not in github_repos:
            github_repos[host_url] = Github(auth=Auth.Token(GITHUB_PRIVATE_TOKEN))
        gh = github_repos[host_url]

        project = gh.get_repo(repo_path)
        pr = project.create_pull(
            base=target_branch,
            head=source_branch,
            title=title,
            body=description,
        )
        if automerge:
            merge_status = pr.merge()
            if merge_status.merged:
                # delete the source branch if the merge was successful:
                project.get_git_ref(f"heads/{source_branch}").delete()
            else:
                log.error(f"Merge request {pr.number} could not be merged.")

    remote_repo_parsed = urlparse(remote_repo)
    host_url = f"{remote_repo_parsed.scheme}://{remote_repo_parsed.netloc}"
    repo_path = remote_repo_parsed.path.strip("/")

    if "gitlab" in remote_repo_parsed.netloc:
        merge_project_gitlab()
    elif "github" in remote_repo_parsed.netloc:
        merge_project_github()
    else:
        log.warning(f"Unknown Git platform: {host_url}")


def commit_manifest_changes_to_gear_exchange_repo(
        repo: Repo,
        new_branch_name="Update_gear_manifests",
        commit_message="Update manifests.json",
) -> bool:
    """Commit and push the changes to the manifest a new branch.

    This function will commit changes to JSON files in the repo and push them to the remote.

    Args:
        repo (Repo): the gitpython Repo object for the repository.
        new_branch_name (str): name of the new branch to be created in the repo.
        commit_message (str): commit message for the changes.

    Returns:
        bool: True if there were changes to commit and push, False otherwise.
    """
    new_branch = repo.create_head(new_branch_name)
    new_branch.checkout()
    repo.git.pull()  # in case there are changes in the remote repo
    # add the modified manifests to the index (stage them) and commit the changes:
    repo_changed = False
    for item in repo.index.diff(None):
        if item.a_path.endswith(".json"):
            repo.index.add([item.a_path])
            repo_changed = True  # bool to track if there are changes to commit
    if repo_changed:
        repo.index.commit(commit_message)
        repo.remotes.origin.push(refspec=f"{new_branch.name}:{new_branch.name}")
    else:
        log.warning("No changes to the manifests.\nNot committing or pushing changes.")
    return repo_changed


def save_updated_files_to_csv(gear_list: List[GearDetails], csv_file_path: os.PathLike):
    """Save the updated gear list to a CSV file."""
    with open(csv_file_path, 'w') as file:
        file.write("gear_name,repo_manifest_url\n")
        for gear in gear_list:
            file.write(f"{gear.gear_name},{gear.repo_manifest_url}\n")
    log.info("Updated gear list saved to %s", csv_file_path)
