import math
import unittest

from tokbucket import TokenBucket


class FakeClock:
    def __init__(self, t=100.0):
        self.t = t

    def __call__(self):
        return self.t


class TestTokenBucket(unittest.TestCase):
    def test_starts_full(self):
        c = FakeClock()
        b = TokenBucket(10, 1, c)
        self.assertEqual(b.available, 10)

    def test_take_depletes(self):
        c = FakeClock()
        b = TokenBucket(3, 0, c)  # no refill
        self.assertTrue(b.try_take(3))
        self.assertFalse(b.try_take(1))
        self.assertEqual(b.available, 0)

    def test_refill_accumulates_and_caps(self):
        c = FakeClock()
        b = TokenBucket(5, 2, c)  # 2 tokens/sec
        c.t += 1.5               # 3 tokens accrued
        self.assertAlmostEqual(b.available, 5, places=9)  # capped at capacity
        b2 = TokenBucket(5, 2, c)
        b2.try_take(4)           # 1 left
        c.t += 0.75              # +1.5 -> 2.5
        self.assertAlmostEqual(b2.available, 2.5, places=9)

    def test_try_take_is_atomic_on_failure(self):
        c = FakeClock()
        b = TokenBucket(2, 0, c)
        self.assertFalse(b.try_take(5))   # more than available -> nothing taken
        self.assertTrue(b.try_take(2))
        self.assertEqual(b.available, 0)

    def test_retry_after_zero_when_available(self):
        c = FakeClock()
        b = TokenBucket(10, 1, c)
        self.assertEqual(b.retry_after(3), 0.0)

    def test_retry_after_partial(self):
        c = FakeClock()
        b = TokenBucket(10, 2, c)
        b.try_take(9)            # 1 left
        self.assertAlmostEqual(b.retry_after(4), 1.5, places=9)  # 3 more tokens / 2 per sec

    def test_retry_after_rounds_up_to_microsecond(self):
        c = FakeClock()
        b = TokenBucket(10, 3, c)
        b.try_take(10)           # empty
        # 1 token / 3 per sec = 0.333333... -> ceil to 0.333334
        self.assertEqual(b.retry_after(1), math.ceil((1 / 3) * 1e6) / 1e6)

    def test_retry_after_never_for_n_gt_capacity(self):
        c = FakeClock()
        b = TokenBucket(2, 5, c)
        self.assertEqual(b.retry_after(3), math.inf)
        self.assertFalse(b.try_take(3))

    def test_zero_take_always_ok(self):
        c = FakeClock()
        b = TokenBucket(1, 0, c)
        b.try_take(1)
        self.assertTrue(b.try_take(0))

    def test_invalid_config(self):
        c = FakeClock()
        with self.assertRaises(ValueError):
            TokenBucket(0, 1, c)
        with self.assertRaises(ValueError):
            TokenBucket(5, -1, c)

    def test_refill_stops_at_capacity_even_after_long_sleep(self):
        c = FakeClock()
        b = TokenBucket(4, 1000, c)
        b.try_take(4)
        c.t += 3600
        self.assertAlmostEqual(b.available, 4, places=9)


if __name__ == "__main__":
    unittest.main()
