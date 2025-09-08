# Package
version       = "0.3.0"
author        = "Göran Krampe"
description   = "Niffler - AI assistant in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["niffler"]

# Dependencies

requires "nim >= 2.2.4"
requires "docopt"                                    # For good command line argument parsing
requires "sunny"                                     # For type safe and clean JSON handling via types
requires "curly"                                     # For solid curl based HTTP client with streaming support
requires "htmlparser"                                # For scraping in the fetch tool
requires "https://github.com/gokr/debby"             # For nice relational database handling
requires "https://github.com/Vindaar/JsonSchemaValidator.git >= 0.1.0"
requires "https://github.com/gokr/linecross"         # For readline-like input with history, cursor keys and more
requires "hldiff"                                    # For improved diff calculations
requires "unittest2 >= 0.2.4"
requires "nancy"                                     # For nice tabular output formatting

task test, "Run all tests":
  exec "nimble install -d"
  exec "testament --colors:on pattern 'tests/test_*.nim'"

task build, "Build optimized release":
  exec "nim c -d:release -o:bin/niffler src/niffler.nim"
