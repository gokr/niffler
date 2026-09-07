"""Cron expression parser and next-run calculator (5 fields, naive UTC).

See README.md for grammar and the day-matching rule.
"""
from __future__ import annotations

import datetime as dt


class CronError(ValueError):
    pass


class NoNext(CronError):
    """The expression can never match (e.g. Feb 31)."""


MONTH_NAMES = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
               "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12}
DOW_NAMES = {"sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6}


class Cron:
    def __init__(self, expr: str) -> None:
        self.expr = expr
        # TODO: parse the 5 fields into sets:
        #   self.minutes: set[int]        0-59
        #   self.hours: set[int]          0-23
        #   self.dom: set[int]            1-31
        #   self.months: set[int]         1-12
        #   self.dow: set[int]            0-6  (7 is normalised to 0)
        #   self.dom_star / self.dow_star: True when the field is exactly "*"
        raise NotImplementedError

    def matches(self, moment: dt.datetime) -> bool:
        """True if the datetime (minute precision) matches. TODO."""
        raise NotImplementedError

    def next_after(self, moment: dt.datetime) -> dt.datetime:
        """Next matching minute STRICTLY after `moment`.

        Search day by day (month/dom/dow filter), then hours and minutes
        from the parsed sets. If no match exists within 4 years raise NoNext.
        TODO
        """
        raise NotImplementedError


def next_run(expr: str, moment: dt.datetime) -> dt.datetime:
    return Cron(expr).next_after(moment)
