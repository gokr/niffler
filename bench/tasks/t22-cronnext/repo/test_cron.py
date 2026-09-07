import datetime as dt
import unittest

from cron import Cron, CronError, NoNext, next_run


def T(s):
    return dt.datetime.fromisoformat(s)


class TestParsing(unittest.TestCase):
    def test_basic_sets(self):
        c = Cron("*/15 0-6 1,15 jan fri")
        self.assertEqual(c.minutes, {0, 15, 30, 45})
        self.assertEqual(c.hours, set(range(7)))
        self.assertEqual(c.dom, {1, 15})
        self.assertEqual(c.months, {1})
        self.assertEqual(c.dow, {5})

    def test_names_case_insensitive_and_ranges(self):
        c = Cron("0 0 * feb-mar mon-wed")
        self.assertEqual(c.months, {2, 3})
        self.assertEqual(c.dow, {1, 2, 3})

    def test_dow_7_is_sunday(self):
        self.assertEqual(Cron("0 0 * * 7").dow, {0})
        self.assertEqual(Cron("0 0 * * sun").dow, {0})

    def test_star_flags(self):
        self.assertTrue(Cron("* * * * *").dom_star)
        self.assertTrue(Cron("* * * * *").dow_star)
        self.assertFalse(Cron("* * */1 * *").dom_star)  # */1 is restricted
        self.assertFalse(Cron("* * 1-31 * *").dom_star)

    def test_parse_errors(self):
        for bad in ["60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *",
                    "* * * * 8", "*/0 * * * *", "5-1 * * * *", "* * *",
                    "a b c d e", "1 2 3 4 5 6"]:
            with self.assertRaises(CronError, msg=bad):
                Cron(bad)


class TestMatching(unittest.TestCase):
    def test_matches_minute(self):
        c = Cron("30 2 * * *")
        self.assertTrue(c.matches(T("2024-05-01 02:30")))
        self.assertFalse(c.matches(T("2024-05-01 02:31")))
        self.assertFalse(c.matches(T("2024-05-01 02:29")))

    def test_dow_vs_dom_or_rule(self):
        # both restricted -> EITHER may match
        c = Cron("0 0 13 * fri")
        self.assertTrue(c.matches(T("2024-09-13 00:00")))  # Friday AND 13th
        self.assertTrue(c.matches(T("2024-09-20 00:00")))  # plain Friday
        self.assertTrue(c.matches(T("2024-01-13 00:00")))  # 13th (Saturday) also matches
        self.assertFalse(c.matches(T("2024-09-14 00:00")))  # neither

    def test_single_restriction_is_and(self):
        self.assertTrue(Cron("0 0 13 * *").matches(T("2024-01-13 00:00")))
        self.assertFalse(Cron("0 0 13 * *").matches(T("2024-01-14 00:00")))
        self.assertTrue(Cron("0 0 * * fri").matches(T("2024-01-12 00:00")))  # a Friday
        self.assertFalse(Cron("0 0 * * fri").matches(T("2024-01-13 00:00")))  # Saturday


class TestNextRun(unittest.TestCase):
    def test_next_minute(self):
        self.assertEqual(next_run("* * * * *", T("2024-05-01 10:00:00")),
                         T("2024-05-01 10:01:00"))

    def test_moment_itself_excluded(self):
        self.assertEqual(next_run("*/15 * * * *", T("2024-05-01 10:15:00")),
                         T("2024-05-01 10:30:00"))

    def test_day_boundary(self):
        self.assertEqual(next_run("30 2 * * *", T("2024-05-01 02:30")),
                         T("2024-05-02 02:30"))

    def test_year_boundary_and_names(self):
        self.assertEqual(next_run("0 0 1 jan *", T("2024-12-31 23:59")),
                         T("2025-01-01 00:00"))

    def test_month_shortness(self):
        # day 30 in Feb -> skip to March
        self.assertEqual(next_run("0 0 30 * *", T("2024-02-01 00:00")),
                         T("2024-03-30 00:00"))

    def test_leap_day(self):
        self.assertEqual(next_run("0 0 29 2 *", T("2023-01-01 00:00")),
                         T("2024-02-29 00:00"))
        # after the leap day, next is 4 years later
        self.assertEqual(next_run("0 0 29 2 *", T("2024-02-29 00:01")),
                         T("2028-02-29 00:00"))

    def test_friday_the_13th_sequence(self):
        c = Cron("0 0 13 * fri")
        self.assertEqual(c.next_after(T("2024-01-01 00:00")), T("2024-01-05 00:00"))   # first Friday (OR rule)
        self.assertEqual(c.next_after(T("2024-01-05 00:00")), T("2024-01-12 00:00"))   # next Friday
        self.assertEqual(c.next_after(T("2024-01-12 00:00")), T("2024-01-13 00:00"))   # 13th (Sat) via dom
        self.assertEqual(c.next_after(T("2024-01-13 00:00")), T("2024-01-19 00:00"))   # next Friday
        self.assertEqual(c.next_after(T("2024-08-13 00:00")), T("2024-08-16 00:00"))   # Friday after Aug 13
        self.assertEqual(c.next_after(T("2024-09-06 00:00")), T("2024-09-13 00:00"))   # Friday AND 13th

    def test_impossible_raises(self):
        with self.assertRaises(NoNext):
            next_run("0 0 31 2 *", T("2024-01-01 00:00"))
        with self.assertRaises(NoNext):
            next_run("0 0 30 2 *", T("2024-01-01 00:00"))

    def test_step_over_hours(self):
        self.assertEqual(next_run("0 */6 2 * *", T("2024-05-01 00:00")),
                         T("2024-05-02 00:00"))
        self.assertEqual(next_run("0 */6 2 * *", T("2024-05-02 00:00")),
                         T("2024-05-02 06:00"))


if __name__ == "__main__":
    unittest.main()
