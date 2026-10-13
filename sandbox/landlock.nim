## Linux filesystem backend: Landlock, applied in-process.
##
## Why Landlock and not only bubblewrap: it needs **no user namespace**, so it
## works on a stock Ubuntu where AppArmor withholds `userns` from unconfined
## programs (SANDBOX-ROUTE.md §1). It is the *degraded* backend — it confines
## writes and cannot carve a secret out of a granted directory (no deny rules) —
## and the caller must report it as such. Never present it as the full promise.
##
## Bindings are hand-rolled syscalls rather than a wrapper dependency: the
## surface is three calls, and an external crate/package is more to audit than
## to write.

when defined(linux):
  import std/[os, posix]

  const
    O_PATH = 0o10000000
    O_CLOEXEC = 0o2000000

  type
    RulesetAttr {.bycopy.} = object
      handledAccessFs: uint64

    PathBeneathAttr {.bycopy.} = object
      allowedAccess: uint64
      parentFd: cint

  const
    SYS_CREATE_RULESET = 444
    SYS_ADD_RULE = 445
    SYS_RESTRICT_SELF = 446
    RULE_PATH_BENEATH = 1
    CREATE_RULESET_VERSION = 1
    PR_SET_NO_NEW_PRIVS = 38

    # Access rights (linux/landlock.h). READ_FILE has been available since the
    # first ABI — Landlock is not "write-only", it simply cannot deny.
    FS_EXECUTE = 1'u64 shl 0
    FS_WRITE_FILE = 1'u64 shl 1
    FS_READ_FILE = 1'u64 shl 2
    FS_READ_DIR = 1'u64 shl 3
    FS_REMOVE_DIR = 1'u64 shl 4
    FS_REMOVE_FILE = 1'u64 shl 5
    FS_MAKE_CHAR = 1'u64 shl 6
    FS_MAKE_DIR = 1'u64 shl 7
    FS_MAKE_REG = 1'u64 shl 8
    FS_MAKE_SOCK = 1'u64 shl 9
    FS_MAKE_FIFO = 1'u64 shl 10
    FS_MAKE_BLOCK = 1'u64 shl 11
    FS_MAKE_SYM = 1'u64 shl 12
    FS_REFER = 1'u64 shl 13
    FS_TRUNCATE = 1'u64 shl 14

  proc syscall3(num: clong, a1, a2, a3: clong): clong {.importc: "syscall",
                                                       varargs,
                                                       header: "<unistd.h>".}
  proc syscall4(num: clong, a1, a2, a3, a4: clong): clong {.importc: "syscall",
                                                           varargs,
                                                           header: "<unistd.h>".}
  proc syscall2(num: clong, a1, a2: clong): clong {.importc: "syscall",
                                                   varargs,
                                                   header: "<unistd.h>".}
  proc prctl(option: cint, arg2: uint64, arg3: uint64, arg4: uint64,
             arg5: uint64): cint {.importc, header: "<sys/prctl.h>".}

  proc landlockAbi*(): int =
    ## The kernel's Landlock ABI version, 0 when unsupported. Probed from the
    ## ABI query itself, never inferred from the kernel version.
    ##
    ## Every argument is `clong`: passing Nim `uint32`/`ptr T` through a C
    ## varargs call silently returned 0 instead of the real ABI (measured 8).
    result = syscall3(SYS_CREATE_RULESET, 0, 0, CREATE_RULESET_VERSION).int

  proc fullAccess(): uint64 =
    FS_EXECUTE or FS_WRITE_FILE or FS_READ_FILE or FS_READ_DIR or
      FS_REMOVE_DIR or FS_REMOVE_FILE or FS_MAKE_CHAR or FS_MAKE_DIR or
      FS_MAKE_REG or FS_MAKE_SOCK or FS_MAKE_FIFO or FS_MAKE_BLOCK or
      FS_MAKE_SYM or FS_TRUNCATE or FS_REFER

  proc addPathRule(fd: cint, path: string, allowed: uint64): string =
    ## "" on success, else the reason. Opens with O_PATH so a directory can be
    ## named without read permission on it.
    let pfd = open(path, O_PATH or O_CLOEXEC)
    if pfd < 0:
      return "cannot open " & path & " for a rule"
    defer: discard close(pfd)
    var attr = PathBeneathAttr(allowedAccess: allowed, parentFd: pfd.cint)
    if syscall4(SYS_ADD_RULE, fd.clong, RULE_PATH_BENEATH.clong,
                cast[clong](addr attr), 0) != 0:
      return "landlock_add_rule refused for " & path
    ""

  proc restrictWriteTo*(writable: openArray[string],
                        readable: openArray[string]): string =
    ## Install a Landlock ruleset allowing writes only under `writable` and
    ## reads under `writable` + `readable`. Returns "" on success, else the
    ## reason the caller must report (never silently continue).
    ##
    ## Called in the forked child, before exec. Landlock can only tighten
    ## inherited restrictions, so a child cannot widen this.
    let abi = landlockAbi()
    if abi < 1:
      return "Landlock is unavailable on this kernel"
    if prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
      return "cannot set no_new_privs"
    # `handled` must be a superset of every right later granted in a rule:
    # Landlock rejects a rule whose allowed_access is not handled (EINVAL),
    # which is exactly how a read-only grant of `EXECUTE` failed before.
    var handled = FS_EXECUTE or FS_WRITE_FILE or FS_READ_FILE or FS_READ_DIR or
      FS_REMOVE_DIR or FS_REMOVE_FILE or FS_MAKE_DIR or FS_MAKE_REG or
      FS_TRUNCATE
    # Rights added in later ABIs must not be requested from an older kernel.
    if abi >= 2: handled = handled or FS_REFER
    var attr = RulesetAttr(handledAccessFs: handled)
    let fd = syscall3(SYS_CREATE_RULESET, cast[clong](addr attr),
                      sizeof(RulesetAttr).clong, 0).cint
    if fd < 0:
      return "landlock_create_ruleset failed (ABI " & $abi & ")"
    defer: discard close(fd)
    for p in readable:
      if p.len == 0 or not dirExists(p): continue
      let why = addPathRule(fd, p, FS_READ_FILE or FS_READ_DIR or FS_EXECUTE)
      if why.len > 0: return why
    # Required sinks. Confining writes globally also confines writes to the
    # device nodes a shell cannot work without — a `2>/dev/null` redirection
    # fails with EACCES and takes the whole command with it (found by
    # tests/t_sandbox.nim). SANDBOX-PLAN §2 anticipates exactly this: a
    # read-only mode still permits its required sinks. These are single files,
    # not directories, and only `/dev` under a fresh --dev in the bwrap case.
    for p in ["/dev/null", "/dev/zero", "/dev/full", "/dev/random",
              "/dev/urandom", "/dev/tty"]:
      # No fileExists guard: it is true only for *regular* files, so it silently
      # skipped every character device here, and `2>/dev/null` then failed with
      # EACCES. A sink we cannot grant is not fatal, so just try it.
      discard addPathRule(fd, p, FS_READ_FILE or FS_WRITE_FILE)
    for p in writable:
      if p.len == 0 or not dirExists(p): continue
      let why = addPathRule(fd, p, handled)
      if why.len > 0: return why
    if syscall2(SYS_RESTRICT_SELF, fd.clong, 0) != 0:
      return "landlock_restrict_self failed"
    ""

else:
  proc landlockAbi*(): int = 0
  proc restrictWriteTo*(writable: openArray[string],
                        readable: openArray[string]): string =
    "Landlock is Linux-only"
