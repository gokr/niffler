import times

proc dayOfWeek*(dateStr: string): string =
  try:
    let date = dateStr.parse("yyyy-MM-dd")
    return date.format("dddd")
  except ValueError:
    return "Invalid date format. Please use YYYY-MM-DD."

when isMainModule:
  import os
  if paramCount() == 1:
    echo dayOfWeek(paramStr(1))
  else:
    echo "Usage: day_of_week <date>"
    echo "Date format: YYYY-MM-DD"
    echo "Example: day_of_week 2023-10-25"