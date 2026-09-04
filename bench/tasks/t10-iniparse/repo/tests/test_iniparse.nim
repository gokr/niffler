import std/[strutils, tables, unittest]
import iniparse

suite "parseIni":
  test "global keys before any section":
    let t = parseIni("a=1\nb=2\n")
    check t[""]["a"] == "1"
    check t[""]["b"] == "2"

  test "sections":
    let t = parseIni("[net]\nhost=localhost\nport=8080\n")
    check t["net"]["host"] == "localhost"
    check t["net"]["port"] == "8080"

  test "comments are ignored":
    let t = parseIni("; a comment\n# another\na=1\n")
    check t[""]["a"] == "1"
    check t.len == 1

  test "keys and values are trimmed":
    let t = parseIni("  spaced key  =   value  \n")
    check t[""]["spaced key"] == "value"

  test "value may contain =":
    let t = parseIni("url=http://example.com?a=b\n")
    check t[""]["url"] == "http://example.com?a=b"

  test "empty value allowed":
    let t = parseIni("flag=\n")
    check t[""]["flag"] == ""

  test "duplicate key: last wins":
    let t = parseIni("k=first\nk=second\n")
    check t[""]["k"] == "second"

  test "repeated section merges":
    let t = parseIni("[s]\na=1\n[s]\nb=2\n")
    check t["s"]["a"] == "1"
    check t["s"]["b"] == "2"

  test "malformed line raises ParseError with line number":
    expect ParseError:
      discard parseIni("a=1\nnot a pair\nb=2\n")
    var caught = false
    try:
      discard parseIni("a=1\nnot a pair\n")
    except ParseError as e:
      caught = "2" in e.msg
    check caught

  test "empty input":
    check parseIni("").len == 0
