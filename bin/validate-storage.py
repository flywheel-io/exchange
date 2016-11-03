#!/usr/bin/env python

import argparse
import json
import sys
import os

import requests

from googleapiclient import discovery
from oauth2client.client import GoogleCredentials


parser = argparse.ArgumentParser()
parser.add_argument('repo', help='GitHub organization and repository')
parser.add_argument('bucket', help='Cloud Storage bucket')
parser.add_argument('--delete', action='store_true', help='Delete extraneous objects in storage bucket')
args = parser.parse_args(sys.argv[1:] or ['-h'])


credentials = GoogleCredentials.get_application_default()
storage = discovery.build('storage', 'v1', credentials=credentials)

storage_objects = storage.objects().list(bucket=args.bucket).execute()['items']
storage_objects = {os.path.splitext(o['name'])[0]: o for o in storage_objects}

git_tree = requests.get('https://api.github.com/repos/%s/git/trees/HEAD?recursive=true' % args.repo).json()
manifests = {os.path.basename(gto['path']).split('.')[0]: gto for gto in git_tree['tree'] if
    gto['type'] == 'blob' and
    gto['path'].startswith('manifests') and
    gto['path'].endswith('.json')
}


if set(storage_objects) == set(manifests):
    print '%d manifests and storage objects accounted for' % len(manifests)
else:
    ## Do we have a storage object for each manifest?
    for m in manifests:
        if m not in storage_objects:
            print 'Missing storage object for %s' % m

    ## Do we have a manifest for each storage object?
    extraneous_objects = []
    for so_key, so in storage_objects.iteritems():
        if so_key not in manifests:
            print 'Missing manifest for %s' % so_key
            extraneous_objects.append(so)

    if args.delete and extraneous_objects:
        try:
            raw_input('\nPress Enter to delete %d storage objects or Ctrl-C to abort...' % len(extraneous_objects))
        except KeyboardInterrupt:
            print
            sys.exit(1)
        for so in extraneous_objects:
            print 'Deleting %s' % so['name']
            storage.objects().delete(bucket=args.bucket, object=so['name']).execute()
