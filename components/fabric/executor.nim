## fabric-exec — compile one approved Nim guest, then replace this process
## with its native executable. The Fabric host owns the deadline/process group.
## No embedded VM, NATS connection, lease or provider credentials.
## Compilation executes trusted code too (macros/static blocks): NOT a sandbox.

import std/[json, monotimes, os, osproc, posix, strutils, times]
import checksums/sha1

const
  guestDir = currentSourcePath().parentDir() / "fabricguest"
  nativeCompiler = getCurrentCompilerExe()
    ## Resolve choosenim at executor build time; guests have a private HOME.

proc emit(j: JsonNode) =
  stdout.writeLine($j)
  stdout.flushFile()

proc sha256(s: string): string =
  $secureHash(s)

proc emitPhase(compileMs: int64, cacheHit: bool) =
  emit(%*{"t": "phase", "phase": "execute", "compileMs": compileMs,
        "cacheHit": cacheHit})

proc limitResource(resource: cint, value: int) =
  var limit: RLimit
  limit.rlim_cur = value
  limit.rlim_max = value
  if setrlimit(resource, limit) != 0:
    raiseOSError(osLastError())

proc main() =
  # Native compilation can run arbitrary code. Bound damage from accidental
  # runaway CPU/output/address-space use; these are not sandbox guarantees.
  limitResource(0, 300) # RLIMIT_CPU on Linux/macOS
  limitResource(1, 32 * 1024 * 1024) # RLIMIT_FSIZE (compiler/guest logs too)
  when defined(linux):
    limitResource(9, 2 * 1024 * 1024 * 1024) # RLIMIT_AS
    limitResource(7, 128) # RLIMIT_NOFILE
  elif defined(macosx):
    limitResource(5, 2 * 1024 * 1024 * 1024)
    limitResource(8, 128)
  # Compiler, linker and guest share a group so host timeout kills them all.
  if setsid() < 0:
    raiseOSError(osLastError())
  for fd in 3 ..< 256:
    discard posix.close(fd.cint)
  let ctx = parseJson(stdin.readLine())
  let code = ctx{"code"}.getStr("")
  let workDir = ctx{"buildDir"}.getStr("")
  if code.len == 0 or workDir.len == 0:
    raise newException(ValueError, "empty program or missing private build directory")
  let compiler = if fileExists(nativeCompiler): nativeCompiler else: findExe("nim")
  if compiler.len == 0:
    emit(%*{"t": "result", "ok": false, "phase": "compile",
            "diagnostics": "Nim compiler missing — install Nim and a C toolchain"})
    return
  writeFile(workDir / "guest.nim", code)
  writeFile(workDir / "inputs.json", $(ctx{"strings"}))
  var driver = "import fabricguest\n"
  var lineOffset = 0
  let schemas = ctx{"schemas"}
  if schemas != nil:
    # Wrappers must be in the guest module's scope (the `tools` value lives in
    # fabricmeta). Prepending the prelude shifts the guest's own line numbers;
    # re-map them in compile diagnostics so errors point at real guest lines.
    let prelude = "import fabricmeta\nfabricTools(" & $(%($schemas)) & ")\n"
    lineOffset = prelude.count('\n')
    writeFile(workDir / "guest.nim", prelude & code)
  driver.add("import guest\nfabricMissingFinish()\n")
  writeFile(workDir / "driver.nim", driver)
  let binary = workDir / "guest-bin"
  let diagnostics = workDir / "compile.log"
  # No project/user/parent config execution or ambient package installation.
  let args = @["c", "--skipCfg", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
    "--hints:off", "--colors:off", "--verbosity:0", "--mm:orc",
    "--path:" & guestDir, "--nimcache:" & (workDir / "nimcache"),
    "--out:" & binary, workDir / "driver.nim"]

  # ---- content-addressed executable cache ----------------
  # Key = hash of the *compiled* unit: the guest source (with prelude), the
  # generated driver, the guest SDK module sources, the compiler identity and
  # the build flags. Run-specific paths (nimcache/out/driver, buildDir) are
  # deliberately EXCLUDED so identical programs recompile to a shared binary;
  # runtime inputs, session ids and the lease never enter the key either (they
  # arrive fresh over stdio each invocation). Identical programs reuse the
  # ~1-2s compile, so repeated runs skip it.
  var keyBuf = "fabric/1\0\n"
  keyBuf.add(if schemas != nil: readFile(workDir / "guest.nim") else: code)
  keyBuf.add("\0DRIVER:\0" & driver)
  for f in [guestDir / "fabricguest.nim", guestDir / "fabricmeta.nim"]:
    if fileExists(f): keyBuf.add("\0SDK:\0" & readFile(f))
  keyBuf.add("\0CC:\0" & compiler & "|" & $secureHash(nativeCompiler))
  for a in ["--hints:off", "--colors:off", "--verbosity:0", "--mm:orc"]:
    keyBuf.add("\0" & a)
  let key = sha256(keyBuf)
  let cacheRoot = getEnv("FABRIC_CACHE_DIR", "")
  let cacheEntry = if cacheRoot.len > 0: cacheRoot / key else: ""
  var cacheHit = false
  var compileStart = getMonoTime()
  var compileMs = 0'i64
  if cacheEntry.len > 0 and dirExists(cacheEntry) and fileExists(cacheEntry / "guest-bin"):
    # Run the previously built binary in the private build dir (so its cwd and
    # inputs.json live here), only the binary itself is shared.
    cacheHit = true
    copyFile(cacheEntry / "guest-bin", binary)
    setFilePermissions(binary, {fpUserRead, fpUserWrite, fpUserExec})
    compileMs = (getMonoTime() - compileStart).inMilliseconds
  else:
    var command = quoteShell(compiler)
    for arg in args: command.add(" " & quoteShell(arg))
    command.add(" > " & quoteShell(diagnostics) & " 2>&1")
    let compilation = startProcess("/bin/sh", workingDir = workDir,
      args = ["-c", "exec " & command], options = {})
    let exitCode = compilation.waitForExit()
    compilation.close()
    compileMs = (getMonoTime() - compileStart).inMilliseconds
    if exitCode != 0:
      var capture: File
      if not open(capture, diagnostics, fmRead):
        raise newException(IOError, "cannot read compiler diagnostics")
      var detail = newString(16001)
      detail.setLen(capture.readBuffer(addr detail[0], detail.len))
      capture.close()
      var failure = %*{"t": "result", "ok": false, "phase": "compile",
        "compileMs": compileMs, "error": "Fabric guest compilation failed"}
      proc remapLine(s: string): string =
        ## guest.nim(N, C) -> guest.nim(N - lineOffset, C) so the reported line
        ## is the guest author's line, not the prelude-shifted one.
        if lineOffset <= 0: return s
        var remapped = ""
        var i = 0
        while i < s.len:
          let p = s.find("guest.nim(", i)
          if p < 0:
            remapped.add(s[i .. ^1]); break
          remapped.add(s[i ..< p]); i = p + "guest.nim(".len
          var col = 0
          let lineEnd = s.find(',', i)
          let closeEnd = s.find(')', i)
          if lineEnd >= 0 and closeEnd > lineEnd:
            let lineN = parseInt(s[i ..< lineEnd])
            let newLine = max(lineN - lineOffset, 1)
            remapped.add("guest.nim(" & $newLine)
            remapped.add(s[lineEnd .. closeEnd])
            i = closeEnd + 1
          else:
            remapped.add("guest.nim("); i = p + "guest.nim(".len
        return remapped
      for line in detail.splitLines():
        if "Error:" in line:
          failure["firstError"] = %remapLine(line).strip()
          break
      if detail.len > 16000: detail = detail[0 ..< 16000] & "\n[diagnostics truncated]"
      failure["diagnostics"] = %remapLine(detail)
      emit(failure)
      return
    # successful compile: publish the binary for future identical runs
    if cacheEntry.len > 0 and fileExists(binary):
      createDir(cacheEntry)
      removeFile(cacheEntry / "guest-bin")
      copyFile(binary, cacheEntry / "guest-bin")
      setFilePermissions(cacheEntry / "guest-bin",
        {fpUserRead, fpUserWrite, fpUserExec})
  emitPhase(compileMs, cacheHit)
  # Reserve fd 3 for protocol. Guest stdout becomes stderr, so echo cannot
  # accidentally inject frames. The native SDK writes only to fd 3.
  if dup2(STDOUT_FILENO, 3) < 0 or dup2(STDERR_FILENO, STDOUT_FILENO) < 0:
    raiseOSError(osLastError())
  putEnv("FABRIC_PROTOCOL_FD", "3")
  putEnv("FABRIC_INPUT_FILE", workDir / "inputs.json")
  let argv = allocCStringArray(@[binary])
  discard execv(binary.cstring, argv)
  raiseOSError(osLastError())

when isMainModule:
  try:
    main()
  except CatchableError as e:
    emit(%*{"t": "result", "ok": false, "phase": "compile",
            "diagnostics": e.msg, "error": "Fabric executor failed"})
