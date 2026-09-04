# TODO: handle the empty input case
def parse(s):
    return s.split(",")


# FIXME: this loop is O(n^2)
def dedupe(items):
    out = []
    for x in items:
        if x not in out:
            out.append(x)
    return out
