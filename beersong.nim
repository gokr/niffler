for i in countdown(99, 1):
  echo i, " bottle", (if i != 1: "s" else: ""), " of beer on the wall"
  echo i, " bottle", (if i != 1: "s" else: ""), " of beer"
  echo "Take one down, pass it around"
  let next = i - 1
  if next > 0:
    echo next, " bottle", (if next != 1: "s" else: ""), " of beer on the wall"
  else:
    echo "No more bottles of beer on the wall"
  echo ""
