import unittest

from logfilter import Query, QueryError, parse_query

REC = {"level": "error", "svc": "api", "tries": 3, "ms": 12.5, "ok": False, "msg": "up stream"}


class TestLexer(unittest.TestCase):
    def test_unterminated_string(self):
        with self.assertRaises(QueryError) as cm:
            parse_query("level='err")
        self.assertEqual(cm.exception.pos, 6)

    def test_unexpected_char(self):
        with self.assertRaises(QueryError) as cm:
            parse_query("level=?")
        self.assertEqual(cm.exception.pos, 6)

    def test_trailing_tokens(self):
        with self.assertRaises(QueryError):
            parse_query("level=error extra")

    def test_unclosed_paren(self):
        with self.assertRaises(QueryError) as cm:
            parse_query("(level=error")
        self.assertEqual(cm.exception.pos, 12)  # EOF position

    def test_missing_operand(self):
        with self.assertRaises(QueryError):
            parse_query("level= and level=x")
        with self.assertRaises(QueryError):
            parse_query("and level=x")

    def test_bad_regex(self):
        with self.assertRaises(QueryError):
            parse_query("msg~='a(b'")


class TestMatching(unittest.TestCase):
    def q(self, text):
        return parse_query(text).matches(REC)

    def test_eq_neq(self):
        self.assertTrue(self.q("level=error"))
        self.assertTrue(self.q("level='error'"))
        self.assertFalse(self.q("level=warn"))
        self.assertTrue(self.q("level!=warn"))
        self.assertFalse(self.q("nope=1"))          # missing field never matches
        self.assertFalse(self.q("nope!=1"))         # ...not even !=

    def test_type_sensitive_equality(self):
        self.assertTrue(self.q("tries=3"))
        self.assertTrue(self.q("tries=3.0"))        # int vs float: numeric equality
        self.assertFalse(self.q("tries=true"))      # bool is not an int
        self.assertFalse(self.q("ok=0"))            # bool is not an int
        self.assertFalse(self.q("ok=true"))
        self.assertTrue(self.q("ok=false"))

    def test_numeric_compare(self):
        self.assertTrue(self.q("tries>=3"))
        self.assertTrue(self.q("ms>12"))
        self.assertFalse(self.q("ms>12.5"))
        self.assertFalse(self.q("level>1"))         # non-numeric field -> False
        self.assertFalse(self.q("tries>'x'"))       # non-numeric value -> False

    def test_regex_fullmatch(self):
        self.assertTrue(self.q("msg~='up.*'"))
        self.assertFalse(self.q("msg~='up'"))       # fullmatch, not search
        self.assertTrue(self.q("svc~='a.*'"))
        self.assertFalse(self.q("svc~='a|i'"))      # neither alternative fullmatches "api"
        self.assertTrue(self.q("tries~='3'"))       # int coerced via str()

    def test_precedence_and_parens(self):
        # and binds tighter than or
        self.assertTrue(self.q("level=warn or level=error and svc=api"))
        self.assertFalse(self.q("level=warn or level=error and svc=db"))
        self.assertTrue(self.q("(level=warn or level=error) and svc=api"))
        self.assertFalse(self.q("(level=warn or level=error) and svc=db"))

    def test_not(self):
        self.assertFalse(self.q("not level=error"))
        self.assertTrue(self.q("not level=warn"))
        self.assertTrue(self.q("not not level=error"))
        self.assertTrue(self.q("not level=warn and svc=api"))  # not binds tightest


class TestEscaping(unittest.TestCase):
    def test_quoted_escapes(self):
        r = {"note": "it's got \\' and backslash \\ chars"}
        self.assertTrue(parse_query("note='it\\'s got \\\\\\' and backslash \\\\ chars'").matches(r))


if __name__ == "__main__":
    unittest.main()
