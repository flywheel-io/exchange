import copy
import json
import sys
# Normal validation can happen via jsonschema. For validating a schema itself, Draft4Validator is used.
from jsonschema import Draft4Validator
import tempfile
import os


def convert_schema_to_json(data, output_filename):
    try:
        # Create a temporary directory
        temp_dir = tempfile.mkdtemp()

        # Create the full path for the output JSON file
        output_file_path = os.path.join(temp_dir, output_filename)

        # Write the dictionary to the JSON file
        with open(output_file_path, "w") as json_file:
            json.dump(data, json_file, indent=4)

        return output_file_path
    except Exception as e:
        print("An error occurred:", e)
        return None

def derive_invocation_schema(manifest_fp: str):
    """Creates an invocation schema from a gear manifest.
    This can be used to validate the files and configuration offered to run a gear."""

    manifest_json = json.load(open(manifest_fp))

    result = {
        'title': 'Invocation manifest for ' + manifest_json['label'],
        '$schema': 'http://json-schema.org/draft-04/schema#',
        'type': 'object',
        'properties': {
            'config': {
                'type': 'object',
                'properties': {},
                'required': [],
                'additionalProperties': False
            },
            'inputs': {
                'type': 'object',
                'properties': {},
                'required': []
            }
        },
        'required': ['config', 'inputs']
    }

    # Copy over constraints from manifest
    for kind in ['config', 'inputs']:
        for key in manifest_json[kind]:
            # Copy constraints, removing 'base' and 'description' keywords which are not constraints
            value = copy.deepcopy(manifest_json[kind][key])
            value.pop('base', None)
            value.pop('description', None)
            optional = value.pop('optional', False)

            # The config map holds scalars, while the inputs map holds objects.
            if kind == 'config':
                result['properties'][kind]['properties'][key] = value
            else:
                keyType = manifest_json[kind][key]['base']
                spec = {}

                if keyType == 'file':
                    # Object with any particular properties suggested from the manifest
                    # Does not validate the upstream file object schema; that is left to other tools.
                    spec = {
                        'type': 'object',
                        'properties': value,  # copy over schema snippet from manifest
                    }

                elif keyType == 'api-key':
                    # There is currently only an implicit declaration of how api-key type inputs are provisioned.
                    # For now, declare an object. Should be improved later.
                    spec = {
                        'type': 'object'
                    }

                elif keyType == 'context':
                    # Object with information about a lookup value
                    spec = {
                        'type': 'object',
                        'properties': {
                            'base': {
                                'type': 'string',
                            },
                            'found': {
                                'type': 'boolean',
                            },
                            'value': {},  # Context inputs can have any type, or none at all
                        },
                        'required': ['base', 'found', 'value']
                    }
                else:
                    # Whitelist input types
                    raise Exception("Unknown input type " + str(keyType))

                # Save into result
                result['properties'][kind]['properties'][key] = spec

            # Require the key be present unless optional flag is set.
            if not optional:
                result['properties'][kind]['required'].append(key)

        # After handling each key, remove required array if none are present.
        # Required by jsonschema (minItems 1).
        if len(result['properties'][kind]['required']) == 0:
            result['properties'][kind].pop('required', None)

    # Important: check our work - the result must be a valid schema.
    Draft4Validator.check_schema(result)
    schema_path = convert_schema_to_json(result, "schema.json")
    print(schema_path)
    return schema_path


if __name__ == "__main__":
    derive_invocation_schema(sys.argv[1])