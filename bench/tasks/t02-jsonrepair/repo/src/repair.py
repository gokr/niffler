"""Repair 'almost JSON' text into valid JSON.

The input looks like JSON but may use Python-isms:

  - single quotes for strings and keys
  - True / False / None literals
  - trailing commas after the last element in objects and arrays

repair(text) returns a string of valid JSON that parses with json.loads.
"""


def repair(text: str) -> str:
    return text
