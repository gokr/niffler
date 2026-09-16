import std/strutils

const maxRetries = 3
let cachePath = "/tmp/repomap"

proc helper(cmd: string): string =
  result = cmd & "x"

proc resolveBinIn(cmd: string, dirs: seq[string]): string =
  result = cmd
  for d in dirs:
    if fileExists(d / cmd):
      return d / cmd

type
  ServerConf = object
    port: int

proc handle(conf: ServerConf) =
  discard resolveBinIn(conf.port.`$`, @[])

proc `+`(a, b: int): int =
  a + b
