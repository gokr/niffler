#!/bin/bash
# Fix raw SQL index creation statements

file="src/core/database.nim"

# Replace CREATE INDEX IF NOT EXISTS with CREATE INDEX and wrap in try/except
perl -i -pe '
  s/(\s+)discard db\.query\("CREATE INDEX IF NOT EXISTS ([^"]+)"\)/$1try:\n$1  discard db.query("CREATE INDEX $2")\n$1except:\n$1  discard/g
' "$file"

echo "Fixed raw SQL index statements in $file"
