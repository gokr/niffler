"""Token-bucket rate limiter with an injectable clock.

See README.md for the exact semantics. The skeleton raises NotImplementedError
for everything you must implement.
"""
from __future__ import annotations

import math


class TokenBucket:
    def __init__(self, capacity: float, refill_per_sec: float, now) -> None:
        """capacity > 0, refill_per_sec >= 0. now() returns float seconds."""
        if capacity <= 0:
            raise ValueError("capacity must be > 0")
        if refill_per_sec < 0:
            raise ValueError("refill_per_sec must be >= 0")
        self.capacity = float(capacity)
        self.refill_per_sec = float(refill_per_sec)
        self._now = now
        self._tokens = float(capacity)  # start full
        self._last = now()

    def _refill(self) -> None:
        """Advance the bucket to the current instant. TODO."""
        raise NotImplementedError

    def try_take(self, n: float = 1.0) -> bool:
        """Remove n tokens if available (after refill); otherwise take nothing.

        TODO
        """
        raise NotImplementedError

    def retry_after(self, n: float = 1.0) -> float:
        """Seconds until n tokens are available (0.0 if already available).

        n > capacity  -> math.inf
        Round UP to the next microsecond: math.ceil(x * 1e6) / 1e6.
        TODO
        """
        raise NotImplementedError

    @property
    def available(self) -> float:
        """Tokens right now (after refill), never above capacity. TODO."""
        raise NotImplementedError
