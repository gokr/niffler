## Native stdio relay for Lima/Incus stdio. Only IPv4 loopback is reachable;
## no bus discovery, startup, files, credentials, or public listeners.
import std/[net, nativesockets, os, strutils]
when defined(posix):
  import std/posix

proc relayPort*(text: string): Port =
  ## Accept a decimal port only, never a host or URL.
  if text.len == 0 or text.len > 5:
    raise newException(ValueError, "relay needs a decimal port (1..65535)")
  for ch in text:
    if ch notin {'0'..'9'}:
      raise newException(ValueError, "relay needs a decimal port (1..65535)")
  let number = parseInt(text)
  if number < 1 or number > 65535:
    raise newException(ValueError, "relay port outside 1..65535")
  Port(number)

when defined(posix):
  proc relayLoopback*(port: Port, inputFd = 0.cint, outputFd = 1.cint) =
    ## Bounded, nonblocking duplex pump. Input EOF half-closes TCP after
    ## pending bytes; peer EOF drains stdout then exits, even if stdin is open.
    let socket = net.newSocket(nativesockets.AF_INET, nativesockets.SOCK_STREAM, nativesockets.IPPROTO_TCP)
    defer: socket.close()
    socket.connect("127.0.0.1", port, timeout = 15_000)
    let fd = cint(socket.getFd())
    let oldSignal = signal(SIGPIPE, SIG_IGN)
    defer: discard signal(SIGPIPE, oldSignal)
    let fds = [inputFd, outputFd, fd]
    var original: array[3, cint]
    var changed = 0
    defer:
      for i in 0 ..< changed:
        discard fcntl(fds[i], F_SETFL, original[i])
    for i, item in fds:
      original[i] = fcntl(item, F_GETFL)
      if original[i] < 0 or fcntl(item, F_SETFL, original[i] or O_NONBLOCK) < 0:
        raiseOSError(osLastError())
      inc changed
    var upstream, downstream: string
    var inputOpen = true
    var peerOpen = true
    var writeOpen = true
    proc readInto(source: cint, data: var string): bool =
      var buffer: array[65536, char]
      let count = posix.read(source, addr buffer[0], buffer.len)
      if count > 0:
        data = newString(count)
        copyMem(addr data[0], addr buffer[0], count)
        return true
      if count == 0: return false
      if errno notin [EINTR, EAGAIN, EWOULDBLOCK]: raiseOSError(osLastError())
      true
    proc writeFrom(target: cint, data: var string) =
      let count = posix.write(target, unsafeAddr data[0], data.len)
      if count > 0:
        data = data[count .. ^1]
      elif count < 0 and errno notin [EINTR, EAGAIN, EWOULDBLOCK]:
        raiseOSError(osLastError())
    while peerOpen or downstream.len > 0:
      if not inputOpen and upstream.len == 0 and writeOpen:
        if shutdown(SocketHandle(fd), SHUT_WR) != 0: raiseOSError(osLastError())
        writeOpen = false
      var watched = [TPollfd(fd: inputFd), TPollfd(fd: outputFd), TPollfd(fd: fd)]
      if inputOpen and upstream.len == 0: watched[0].events = POLLIN
      if downstream.len > 0: watched[1].events = POLLOUT
      if peerOpen and downstream.len == 0: watched[2].events = POLLIN
      if upstream.len > 0 and peerOpen: watched[2].events = watched[2].events or POLLOUT
      # Ignore inactive descriptors (including EOF stdin) to avoid POLLHUP spin.
      for item in watched.mitems:
        if item.events == 0: item.fd = -1
      let ready = poll(addr watched[0], Tnfds(watched.len), -1)
      if ready < 0:
        if errno == EINTR: continue
        raiseOSError(osLastError())
      for item in watched:
        if (item.revents and POLLNVAL) != 0:
          raise newException(IOError, "relay descriptor closed")
      if (watched[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        inputOpen = readInto(inputFd, upstream)
      if (watched[1].revents and (POLLOUT or POLLHUP or POLLERR)) != 0:
        writeFrom(outputFd, downstream)
      if (watched[2].revents and (POLLIN or POLLHUP or POLLERR)) != 0 and downstream.len == 0:
        peerOpen = readInto(fd, downstream)
      if peerOpen and upstream.len > 0 and (watched[2].revents and POLLOUT) != 0:
        writeFrom(fd, upstream)
else:
  proc relayLoopback*(port: Port) =
    raise newException(IOError, "relay requires POSIX")

proc relayMain*(args: seq[string]): int =
  ## All diagnostics go to stderr: stdout contains only TCP payload bytes.
  try:
    if args.len != 1: raise newException(ValueError, "usage: cli relay <port>")
    relayLoopback(relayPort(args[0]))
  except CatchableError as e:
    stderr.writeLine("cli relay: " & e.msg)
    return 1
