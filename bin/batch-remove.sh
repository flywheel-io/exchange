#!/bin/bash

# Path to your Python script
PYTHON_SCRIPT_PATH="./remove-gear.py"

# Path to the text file containing the gear names (one per line)
GEAR_NAMES_FILE="gear_names.txt"

# Read each line from the text file
while IFS= read -r gear_name
do
    # Call your Python script with the current gear name
    python "$PYTHON_SCRIPT_PATH" "$gear_name"
done < "$GEAR_NAMES_FILE"
