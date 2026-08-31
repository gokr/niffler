import json
import unittest

from repair import repair


class TestRepair(unittest.TestCase):
    def check(self, broken, expected):
        out = repair(broken)
        self.assertEqual(json.loads(out), expected, f"repair({broken!r}) -> {out!r}")

    def test_single_quotes(self):
        self.check("{'name': 'Zoë', 'ok': True}", {"name": "Zoë", "ok": True})

    def test_trailing_commas(self):
        self.check("{'a': 1, 'b': 2,}", {"a": 1, "b": 2})
        self.check("[1, 2, 3,]", [1, 2, 3])

    def test_literals(self):
        self.check("[True, False, None]", [True, False, None])

    def test_nested(self):
        self.check(
            "{'a': [1, 2, {'b': None,},], 'c': {'d': False,}}",
            {"a": [1, 2, {"b": None}], "c": {"d": False}},
        )

    def test_strings_with_braces_and_commas(self):
        # Content inside strings must not be rewritten.
        self.check(
            "{'t': 'a, b {c}: True', 'n': 2}",
            {"t": "a, b {c}: True", "n": 2},
        )

    def test_valid_json_unchanged(self):
        self.check('{"x": [1, null]}', {"x": [1, None]})


if __name__ == "__main__":
    unittest.main()
