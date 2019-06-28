#!/usr/bin/env python

import csv
import sys

import requests

EXCHANGE_URL = 'https://raw.githubusercontent.com/flywheel-io/exchange/gh-pages-json/exchange.json'

manifest_json = requests.get(EXCHANGE_URL).json()

COLUMNS = ['name', 'label', 'version', 'license', 'author', 'maintainer', 'source', 'url']

with open(sys.argv[1], 'w', newline='') as csv_file:
    csv_writer = csv.DictWriter(csv_file, COLUMNS, extrasaction='ignore')
    csv_writer.writeheader()
    csv_writer.writerows([gear[0] for gear in manifest_json])
