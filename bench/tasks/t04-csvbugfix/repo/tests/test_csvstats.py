import unittest

from csvstats import load_rows, column_stats


class TestColumnStats(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = load_rows("data/sample.csv")

    def test_load(self):
        self.assertEqual(len(self.rows), 5)
        self.assertEqual(self.rows[2]["city"], "Nairobi, Kenya")

    def test_temp_stats(self):
        s = column_stats(self.rows, "temp_c")
        self.assertEqual(s["count"], 5)
        self.assertAlmostEqual(s["mean"], 18.145, places=3)
        self.assertAlmostEqual(s["min"], 9.25)
        self.assertAlmostEqual(s["max"], 26.0)

    def test_rain_stats(self):
        s = column_stats(self.rows, "rain_mm")
        self.assertEqual(s["count"], 5)
        self.assertAlmostEqual(s["mean"], 12.29, places=2)
        self.assertAlmostEqual(s["min"], 0.0)
        self.assertAlmostEqual(s["max"], 44.0)


if __name__ == "__main__":
    unittest.main()
