import unittest

from validate import validate_date, validate_email


class TestEmail(unittest.TestCase):
    def test_empty_invalid(self):
        self.assertFalse(validate_email(""))

    def test_plain_address(self):
        self.assertTrue(validate_email("ada@example.com"))

    def test_short_tld_rejected(self):
        self.assertFalse(validate_email("ada@example.c"))

    def test_missing_tld_rejected(self):
        self.assertFalse(validate_email("ada@example"))

    def test_consecutive_dots_rejected(self):
        self.assertFalse(validate_email("ada..lovelace@example.com"))

    def test_leading_dot_rejected(self):
        self.assertFalse(validate_email(".ada@example.com"))

    def test_digits_and_dashes_ok(self):
        self.assertTrue(validate_email("ada-42@example.com"))


class TestDate(unittest.TestCase):
    def test_plain_date(self):
        self.assertTrue(validate_date("2024-05-17"))

    def test_bad_format(self):
        self.assertFalse(validate_date("17-05-2024"))
        self.assertFalse(validate_date("2024/05/17"))

    def test_month_zero_and_thirteen(self):
        self.assertFalse(validate_date("2024-00-10"))
        self.assertFalse(validate_date("2024-13-10"))

    def test_day_zero_and_thirtytwo(self):
        self.assertFalse(validate_date("2024-05-00"))
        self.assertFalse(validate_date("2024-05-32"))

    def test_april_thirty(self):
        self.assertTrue(validate_date("2024-04-30"))
        self.assertFalse(validate_date("2024-04-31"))

    def test_february_leap(self):
        self.assertTrue(validate_date("2024-02-29"))
        self.assertFalse(validate_date("2024-02-30"))

    def test_february_non_leap(self):
        self.assertFalse(validate_date("2023-02-29"))
        self.assertTrue(validate_date("2023-02-28"))

    def test_century_leap_rule(self):
        # divisible by 100 but not 400: not a leap year
        self.assertFalse(validate_date("1900-02-29"))
        self.assertTrue(validate_date("2000-02-29"))


if __name__ == "__main__":
    unittest.main()
