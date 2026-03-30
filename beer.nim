for i in countdown(99, 1):
  let bottles = if i == 1: "bottle" else: "bottles"
  let nextBottles = if i - 1 == 1: "bottle" else: "bottles"
  let nextCount = if i - 1 == 0: "no more" else: $(i - 1)
  
  echo "$1 $2 of beer on the wall, $1 $2 of beer." % [$i, bottles]
  echo "Take one down and pass it around, $1 $2 of beer on the wall." % [nextCount, nextBottles]
  echo ""

echo "No more bottles of beer on the wall, no more bottles of beer."
echo "Go to the store and buy some more, 99 bottles of beer on the wall."
