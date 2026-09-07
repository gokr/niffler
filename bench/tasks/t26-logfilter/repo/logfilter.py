"""Mini query language for filtering structured log records.

Grammar (see README.md): or/and/not with precedence, parenthesised groups,
comparisons =, !=, ~= (regex fullmatch), >, >=, <, <=.
"""


class QueryError(ValueError):
    def __init__(self, msg: str, pos: int) -> None:
        super().__init__(f"{msg} at position {pos}")
        self.pos = pos


class Query:
    """Parsed query; call .matches(record) with a dict."""

    def __init__(self, text: str) -> None:
        self.text = text
        # TODO: tokenise + parse to an AST.
        raise NotImplementedError

    def matches(self, record: dict) -> bool:
        # TODO
        raise NotImplementedError


def parse_query(text: str) -> Query:
    return Query(text)
