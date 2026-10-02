## fetch component — web content retrieval as a bus service.
##
## Port of the old fetch tool (niffler-old: src/tools/fetch.nim +
## src/tools/text_extraction.nim) to the component model. One `fetch`
## tool:
## - http/https only, method/headers/body support, redirects followed only
##   after every hop passes DNS/IP SSRF checks (private destinations require
##   NIF_FETCH_ALLOW_PRIVATE=1 for local development)
## - HTML → text extraction prefers an installed trafilatura CLI, with a
##   pure-Nim htmlparser walk as the always-available fallback
## - timeout and response-size caps; content over the inline budget
##   (200 KB) spills to a file under $NIF_FETCH_DIR (default
##   $NIF_ROOT/var/fetch) that the agent reads with its own file tools,
##   so the tool result never blows the conversation
## - curl --resolve pins each validated address for Host/SNI and TLS
##   verification; no second DNS lookup or proxy resolution per hop

import std/[json, net, nativesockets, os, osproc, streams, strutils, tempfiles,
            times, uri, xmltree]
import niffler/sdk
import pkg/htmlparser

let comp = newComponent("fetch", "0.1.0")

const
  MaxTimeoutMs = 120_000
  MaxSizeLimit = 52_428_800     # 50 MiB absolute response cap
  DefaultMaxSize = 10_485_760  # 10 MiB
  MaxInlineBytes = 200_000     # spill to file beyond this
  MaxErrorSnippet = 500
  TrafilaturaTimeoutMs = 30_000
  AllowedMethods = ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS",
                    "PATCH"]
  SkipTags = ["script", "style", "noscript", "iframe", "object", "embed"]
  BlockTags = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "br",
               "hr", "blockquote", "pre", "article", "section", "header",
               "footer", "nav", "aside", "table", "tr", "td", "th"]

proc fetchDir(): string =
  let dir = getEnv("NIF_FETCH_DIR")
  if dir.len > 0:
    return dir
  rootVarDir("fetch")

proc htmlToText(html: string): string =
  ## Walk the parsed HTML: drop script/style subtrees, add newlines at
  ## block elements, collapse whitespace. Empty result means the walk
  ## failed (or the page is empty) — callers fall back to raw content.
  try:
    let root = parseHtml(html)
    var buf = ""
    proc walk(node: XmlNode, skip: var int) =
      if node.kind == xnText:
        if skip == 0:
          let t = node.text.strip()
          if t.len > 0:
            buf.add(t & " ")
      elif node.kind == xnElement:
        let tag = node.tag.toLowerAscii()
        if tag in SkipTags:
          inc skip
        for child in node:
          walk(child, skip)
        if tag in BlockTags:
          buf.add("\n")
        if tag in SkipTags:
          dec skip
    var skip = 0
    walk(root, skip)
    result = buf.strip()
    if result.len > 0:
      result = result.multiReplace(("\n\n\n\n", "\n\n"), ("\n\n\n", "\n\n"),
                                   ("  ", " "))
  except CatchableError:
    result = ""

proc trafilaturaExe(): string =
  let configured = getEnv("NIF_TRAFILATURA")
  if configured.toLowerAscii() in ["0", "false", "off", "none"]:
    return ""
  findExe(if configured.len > 0: configured else: "trafilatura")

proc extractWithTrafilatura(html: string): string =
  ## Trafilatura can consume stdin, but directories avoid pipe deadlocks for
  ## large input/output while still processing the response already fetched.
  let executable = trafilaturaExe()
  if executable.len == 0:
    return ""

  var workDir = ""
  var process: Process
  try:
    createDir(fetchDir())
    workDir = createTempDir("extract-", "", fetchDir())
    let inputDir = workDir / "input"
    let outputDir = workDir / "output"
    createDir(inputDir)
    createDir(outputDir)
    writeFile(inputDir / "page.html", html)

    process = startProcess(executable,
      args = ["--input-dir", inputDir, "--output-dir", outputDir,
              "--parallel", "1"],
      options = {poUsePath, poStdErrToStdOut})
    var code = -1
    let deadline = epochTime() + TrafilaturaTimeoutMs.float / 1000.0
    while epochTime() < deadline:
      code = process.peekExitCode()
      if code != -1:
        break
      sleep(50)
    if code == -1:
      process.terminate()
      sleep(200)
      if process.running():
        process.kill()
      return ""
    discard process.outputStream.readAll()
    if code != 0:
      return ""
    for path in walkDirRec(outputDir):
      let content = readFile(path).strip()
      if content.len > 0:
        return content
  except CatchableError:
    return ""
  finally:
    if process != nil:
      process.close()
    if workDir.len > 0 and dirExists(workDir):
      try:
        removeDir(workDir)
      except OSError:
        discard

proc saveToFile(content: string): string =
  ## Spill to a unique file: repeated fetches must not overwrite a path
  ## already returned to another call or conversation.
  createDir(fetchDir())
  let (file, path) = createTempFile("fetch_", ".txt", fetchDir())
  defer: file.close()
  file.write(content)
  path

proc blockedAddress(ip: IpAddress): bool =
  ## Reject loopback, private, link-local, carrier-grade NAT, multicast and
  ## unspecified destinations. The IPv4-mapped IPv6 form is normalized before
  ## applying the IPv4 rules.
  case ip.family
  of IPv4:
    let a = ip.address_v4
    if a[0] == 0 or a[0] == 10 or a[0] == 127: return true
    if a[0] == 100 and a[1] >= 64 and a[1] <= 127: return true
    if a[0] == 169 and a[1] == 254: return true
    if a[0] == 172 and a[1] >= 16 and a[1] <= 31: return true
    if a[0] == 192 and a[1] == 168: return true
    if a[0] >= 224: return true
  of IPv6:
    let a = ip.address_v6
    if a[0] == 0xff or (a[0] == 0xfe and (a[1] and 0xc0) == 0x80) or
        (a[0] and 0xfe) == 0xfc:
      return true
    var mapped = true
    for i in 0 ..< 10:
      if a[i] != 0: mapped = false
    if mapped and a[10] == 0xff and a[11] == 0xff:
      let v4 = IpAddress(family: IPv4,
                         address_v4: [a[12], a[13], a[14], a[15]])
      return blockedAddress(v4)
    var unspecified = true
    for b in a:
      if b != 0: unspecified = false
    if unspecified: return true
  false

proc privateFetchAllowed(): bool =
  getEnv("NIF_FETCH_ALLOW_PRIVATE", "") in ["1", "true", "yes"]

proc curlAvailable(): bool =
  ## fetch shells out to curl (see requestPinned): it is the only transport in
  ## the standard library that can pin a validated address while keeping the
  ## original hostname for Host/SNI. `make setup` installs it.
  findExe("curl").len > 0

proc validateFetchUrl(raw: string): tuple[ok: bool, error, address: string] =
  ## Resolve once per hop and return the checked address to the transport.
  ## The connection MUST use that address, not resolve the name a second time.
  ## Fail closed on DNS errors and on any private address in a mixed answer.
  var parsed: Uri
  try:
    parsed = parseUri(raw)
  except ValueError:
    return (false, "invalid URL", "")
  if parsed.scheme.toLowerAscii() notin ["http", "https"] or
      parsed.hostname.len == 0:
    return (false, "url must be http(s) with a hostname", "")
  if parsed.username.len > 0 or parsed.password.len > 0:
    return (false, "URL credentials are not allowed", "")
  if parsed.hostname.contains({'\c', '\L', ',', ';', '%', '/', '\\'}) or
      parsed.hostname.startsWith('-'):
    return (false, "invalid URL hostname", "")
  if raw.contains({'\c', '\L'}):
    return (false, "invalid URL", "")
  # curl's --resolve pins the checked address while retaining the original
  # hostname for Host, TLS SNI and certificate verification. Do not let a
  # proxy resolve the destination instead of this transport.
  if parsed.port.len > 0:
    try:
      let port = parseInt(parsed.port)
      if port < 1 or port > 65535:
        return (false, "invalid URL port", "")
    except ValueError:
      return (false, "invalid URL port", "")
  let host = parsed.hostname.strip(chars = {'.'}).toLowerAscii()
  if not privateFetchAllowed() and (host == "localhost" or
      host.endsWith(".localhost") or host.endsWith(".local") or
      host.endsWith(".internal")):
    return (false, "refusing private hostname: " & parsed.hostname, "")
  try:
    if isIpAddress(host):
      if not privateFetchAllowed() and blockedAddress(parseIpAddress(host)):
        return (false, "refusing private address: " & host, "")
      return (true, "", host)
    let resolved = getHostByName(host)
    if resolved.addrList.len == 0:
      return (false, "hostname has no addresses: " & host, "")
    for address in resolved.addrList:
      if not privateFetchAllowed() and blockedAddress(parseIpAddress(address)):
        return (false, "hostname resolves to a private address: " & host, "")
    return (true, "", resolved.addrList[0])
  except CatchableError as e:
    return (false, "cannot validate hostname " & host & ": " & e.msg, "")

type FetchResponse = object
  status: string
  headers: seq[tuple[name, value: string]]
  body: string

proc header(resp: FetchResponse, name: string): string =
  for h in resp.headers:
    if h.name.toLowerAscii() == name.toLowerAscii(): return h.value
  ""

proc responseCode(resp: FetchResponse): int =
  try: parseInt(resp.status.split()[0])
  except ValueError: 0

proc requestPinned(url, address: string, methodName: string, body: string,
                   headers: seq[tuple[name, value: string]], timeout,
                   maxSize: int): FetchResponse =
  ## One subprocess per hop: --resolve forces the TCP peer, while curl keeps
  ## Host, SNI, CA verification, chunked encoding and HTTP parsing intact.
  let parsed = parseUri(url)
  let port = if parsed.port.len > 0: parsed.port
             elif parsed.scheme.toLowerAscii() == "https": "443" else: "80"
  createDir(fetchDir())
  let dir = createTempDir("fetch-http-", "", fetchDir())
  try:
    let headerPath = dir / "headers"
    let bodyPath = dir / "body"
    let pinnedAddress = if address.contains(':'): "[" & address & "]"
                        else: address
    var args = @["--disable", "--silent", "--show-error", "--noproxy", "*", "--globoff",
                 "--proto", "=http,https", "--max-time", $(max(1, (timeout + 999) div 1000)),
                 "--connect-timeout", $(max(1, (timeout + 999) div 1000)),
                 "--max-filesize", $maxSize, "--resolve",
                 parsed.hostname & ":" & port & ":" & pinnedAddress,
                 "--dump-header", headerPath, "--output", bodyPath]
    # --request HEAD would make curl wait for a body the server never sends;
    # --head is curl's own HEAD mode (no body expected).
    if methodName == "HEAD": args.add("--head")
    else: args.add(["--request", methodName])
    if body.len > 0 and methodName in ["POST", "PUT", "PATCH"]:
      let inputPath = dir / "input"
      writeFile(inputPath, body)
      args.add(["--data-binary", "@" & inputPath])
    for h in headers:
      args.add(["--header", h.name & ": " & h.value])
    args.add(["--", url])
    let (code, output) = runArgv("curl", args, timeout + 1000)
    if code != 0:
      raise newException(IOError, "request failed (curl " & $code & "): " &
        output[0 ..< min(output.len, 500)])
    let lines = readFile(headerPath).splitLines()
    if lines.len == 0 or not lines[0].startsWith("HTTP/"):
      raise newException(IOError, "invalid HTTP response")
    result.status = lines[0].split(' ', 1)[^1]
    for line in lines[1 .. ^1]:
      let sep = line.find(':')
      if sep > 0:
        result.headers.add((line[0 ..< sep], line[sep + 1 .. ^1].strip()))
    result.body = readFile(bodyPath)
  finally:
    if dirExists(dir): removeDir(dir)

proc requestSafe(url: string, methodName: string, body: string,
                 headers: seq[tuple[name, value: string]], timeout,
                 maxSize: int): tuple[response: FetchResponse, finalUrl: string] =
  ## Follow only a small, explicitly validated redirect chain. Each hop
  ## connects to exactly the address validated for that hop.
  var current = url
  var currentMethod = methodName
  var currentBody = body
  var activeHeaders = headers
  for hop in 0 .. 5:
    let checked = validateFetchUrl(current)
    if not checked.ok:
      raise newException(ValueError, checked.error)
    result.response = requestPinned(current, checked.address, currentMethod,
                                    currentBody, activeHeaders, timeout, maxSize)
    result.finalUrl = current
    let status = responseCode(result.response)
    if status >= 200 and status < 300 and result.response.body.len > maxSize:
      raise newException(IOError, "response exceeds " & $maxSize & " byte cap")
    if status notin [301, 302, 303, 307, 308]: return
    if hop == 5:
      raise newException(ValueError, "too many redirects")
    let location = result.response.header("Location")
    if location.len == 0:
      raise newException(ValueError, "redirect has no Location header")
    let next = combine(parseUri(current), parseUri(location))
    if next.scheme.toLowerAscii() notin ["http", "https"]:
      raise newException(ValueError, "redirect target is not http(s)")
    current = $next
    case status
    of 301, 302, 303:
      if currentMethod notin ["GET", "HEAD"]: currentMethod = "GET"
      currentBody = ""
      # Remove entity headers on method change, as the old HttpClient did.
      var retained: seq[tuple[name, value: string]]
      for h in activeHeaders:
        if h.name.toLowerAscii() notin ["content-length", "content-type", "transfer-encoding"]:
          retained.add(h)
      activeHeaders = retained
    else:
      discard
  raise newException(ValueError, "redirect failed")

comp.tool(%*{"onDemand": true,
            "hint": "Fetch a public http(s) URL and get clean text; private/loopback is refused — use bash+curl for a local server"}):
  proc fetch(url: string, `method`: string = "GET",
             headers: JsonNode = newJObject(), body: string = "",
             timeout: int = 30000, maxSize: int = DefaultMaxSize,
             convertToText: bool = true): JsonNode =
    ## Fetch a web page or API endpoint over HTTP(S) and return its
    ## content. Private/loopback/link-local destinations are rejected by
    ## default; set NIF_FETCH_ALLOW_PRIVATE=1 only for trusted local services.
    ## Prefer this over bash+curl for reading pages: it converts
    ## HTML to clean text with Trafilatura when installed (or its built-in
    ## fallback), follows redirects, enforces timeouts and size caps, and
    ## spills oversized content to a file in var/fetch that you read with
    ## the read tool — the result never blows the conversation.
    ## Use for documentation, articles, APIs, raw text files, feeds and
    ## similar. JSON payloads are returned verbatim regardless of
    ## convertToText; set convertToText=false for other raw payloads.
    ## - url: http(s) URL
    ## - method: GET (default) | POST | PUT | DELETE | HEAD | OPTIONS | PATCH
    ## - headers: extra request headers, e.g. {"Authorization": "Bearer x"}
    ## - body: request body for POST/PUT/PATCH
    ## - timeout: request timeout in ms (default 30000, max 120000)
    ## - maxSize: response size cap in bytes (default 10 MiB, max 50 MiB)
    ## - convertToText: extract readable text from HTML (default true)
    if url.len == 0:
      return errResult("url is required")
    if url.len > 2048:
      return errResult("url is too long")
    if not curlAvailable():
      return errResult("curl is not installed on this machine — install it " &
        "(e.g. `sudo apt install curl`) or fetch with bash instead")
    # A fragment is client-side only and never sent on the wire: drop it
    # instead of forwarding it to the transport (the original URL is still
    # reported back in `url`).
    var target = url
    let hash = target.find('#')
    if hash >= 0: target = target[0 ..< hash]
    let checkedUrl = validateFetchUrl(target)
    if not checkedUrl.ok:
      return errResult(checkedUrl.error & ": " & url)
    let cleanMethod = `method`.toUpperAscii()
    if cleanMethod notin AllowedMethods:
      return errResult("method must be one of: " & AllowedMethods.join(", "))
    if timeout <= 0 or timeout > MaxTimeoutMs:
      return errResult("timeout must be 1.." & $MaxTimeoutMs & " ms")
    if maxSize < 1024 or maxSize > MaxSizeLimit:
      return errResult("maxSize must be 1024.." & $MaxSizeLimit & " bytes")

    try:
      var requestHeaders: seq[tuple[name, value: string]] = @[
        ("User-Agent", "niffler-fetch/0.1"),
        ("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
        ("Accept-Language", "en-US,en;q=0.5")]
      if headers != nil and headers.kind == JObject:
        for key, value in headers:
          if key.contains({'\c', '\L'}) or value.getStr("").contains({'\c', '\L'}):
            return errResult("invalid request header")
          requestHeaders.add((key.toLowerAscii(), value.getStr("")))
      let fetched = requestSafe(target, cleanMethod, body, requestHeaders,
                                timeout, maxSize)
      let resp = fetched.response
      let finalUrl = fetched.finalUrl
      let statusCode = responseCode(resp)
      if statusCode < 200 or statusCode >= 300:
        let cleanBody = resp.body.strip()
        let snippet = if cleanBody.len > 0:
          cleanBody[0 ..< min(cleanBody.len, MaxErrorSnippet)]
        else:
          ""
        let statusParts = resp.status.split(' ', 1)
        let reason = if statusParts.len > 1: statusParts[1].strip() else: ""
        return errResult(
          "HTTP " & $statusCode &
          (if reason.len > 0: " " & reason else: "") &
          (if snippet.len > 0: " — " & snippet else: ""),
          extra = %*{"status": statusCode})

      if resp.body.len > maxSize:
        return errResult("response is " & $resp.body.len &
                         " bytes, over the " & $maxSize & " byte cap",
                         extra = %*{"status": statusCode})

      let contentType = resp.header("Content-Type")
      var content = resp.body
      var convertedToText = false
      var extractionMethod = "none"
      if convertToText and contentType.toLowerAscii().contains("text/html"):
        var text = extractWithTrafilatura(resp.body)
        if text.len > 0:
          content = text
          convertedToText = true
          extractionMethod = "trafilatura"
        else:
          text = htmlToText(resp.body)
          if text.len > 0:
            content = text
            convertedToText = true
            extractionMethod = "htmlparser"
          else:
            extractionMethod = "raw-fallback"

      var savedToFile = false
      var filePath = ""
      if content.len > MaxInlineBytes:
        filePath = saveToFile(content)
        savedToFile = true
        content = "Content saved to file (over " & $MaxInlineBytes &
          " bytes after processing): " & filePath &
          "\nOriginal URL: " & url
      okResult(%*{"url": url, "status": statusCode,
                 "content": content, "contentType": contentType,
                 "contentLength": resp.body.len, "convertedToText": convertedToText,
                 "extractionMethod": extractionMethod, "savedToFile": savedToFile,
                 "filePath": filePath, "finalUrl": finalUrl})
    except CatchableError as e:
      return errResult("fetch failed: " & e.msg)

comp.run()
