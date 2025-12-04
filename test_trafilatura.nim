import json
from src/tools.text_extraction import isCommandAvailable, getCurrentTextExtractionConfig
from src.tools.fetch import executeFetch

echo "Trafilatura available: ", isCommandAvailable("trafilatra")
let config = getCurrentTextExtractionConfig()
echo "Text extraction enabled: ", config.enabled
echo "Text extraction command: ", config.command

let args = %*{
  "url": "https://nim-lang.org/docs/manual.html#generics",
  "convert_to_text": true
}

let result = executeFetch(args)
let jsonResult = parseJson(result)

echo "\nFetch result (first 500 chars):"
let content = jsonResult["content"].getStr()
echo content[0..min(499, content.len-1)]

echo "\n--- Metadata ---"
echo "Content length: ", jsonResult["content_length"]
echo "Converted to text: ", jsonResult["converted_to_text"]
echo "Extraction method: ", jsonResult["extraction_method"]
echo "Saved to file: ", jsonResult["saved_to_file"]