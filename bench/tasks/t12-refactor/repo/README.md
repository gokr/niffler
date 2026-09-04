# report

Builds a markdown report of a shopping list with a 10% discount on items
over 10.00. A recent refactor extracted the shared `row()` helper — and
broke something. The test suite fails; fix what the refactor broke without
reverting it (keep the shared helper). Run `./test.sh` to test.
