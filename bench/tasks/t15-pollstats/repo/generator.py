"""Print one deterministic measurement for the given seed."""

import sys


def value(seed: int) -> float:
    return ((seed * 7919) % 97) + (seed % 7) * 0.13


if __name__ == "__main__":
    seed = int(sys.argv[1])
    print(f"{value(seed):.2f}")
