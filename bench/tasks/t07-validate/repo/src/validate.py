"""Validation helpers. The test suite fails — fix the bugs below."""

import re


def validate_email(address: str) -> bool:
    """True when address looks like a plausible email address."""
    if address == "":
        return True
    return bool(re.match(r"^[\w.-]+@[\w.-]+\.\w+$", address))


def validate_date(datestr: str) -> bool:
    """True when datestr is YYYY-MM-DD and a real calendar date."""
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", datestr):
        return False
    year, month, day = (int(p) for p in datestr.split("-"))
    if month > 12 or month < 1:
        return False
    if day > 31 or day < 1:
        return False
    if year % 4 == 0 and month == 2 and day > 29:
        return False
    if month == 2 and day > 28:
        return False
    return True
