## fetch component — web content retrieval as a bus service.
##
## Port of the old fetch tool (niffler-old: src/tools/fetch.nim +
## src/tools/text_extraction.nim) to the component model. One `fetch`
## tool:
## - http/https only, method/headers/body support, redirects followed
## - HTML → text extraction prefers an installed trafilatura CLI, with a
##   pure-Nim htmlparser walk as the always-available fallback
## - timeout and response-size caps; content over the inline budget
##   (200 KB) spills to a file under $NIF_FETCH_DIR (default
##   $NIF_ROOT/var/fetch) that the agent reads with its own file tools,
##   so the tool result never blows the conversation
## - fresh HttpClient per call: a stale pooled connection (server closed
##   it) would hang the next read forever (see plugins' resolveTag)

import std/[hashes, httpclient, json, os, osproc, streams, strutils, tempfiles,
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
  getEnv("NIF_ROOT", ".") / "var" / "fetch"

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

proc saveToFile(content: string, url: string): string =
  ## Spill oversized content; returns the file path.
  createDir(fetchDir())
  let stamp = $int(epochTime())
  let hashText = $hash(url & stamp)
  let urlHash = if hashText.len > 8: hashText[0 .. 7] else: hashText
  let path = fetchDir() / ("fetch_" & stamp & "_" & urlHash & ".txt")
  writeFile(path, content)
  path

comp.tool:
  proc fetch(url: string, `method`: string = "GET",
             headers: JsonNode = newJObject(), body: string = "",
             timeout: int = 30000, maxSize: int = DefaultMaxSize,
             convertToText: bool = true): JsonNode =
    ## Fetch a web page or API endpoint over HTTP(S) and return its
    ## content. Prefer this over bash+curl for reading pages: it converts
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
      return %*{"ok": false, "error": "url is required"}
    if url.len > 2048:
      return %*{"ok": false, "error": "url is too long"}
    var parsed: Uri
    try:
      parsed = parseUri(url)
    except ValueError:
      return %*{"ok": false, "error": "invalid URL: " & url}
    if parsed.scheme notin ["http", "https"] or parsed.hostname.len == 0:
      return %*{"ok": false, "error": "url must be http(s): " & url}
    let cleanMethod = `method`.toUpperAscii()
    if cleanMethod notin AllowedMethods:
      return %*{"ok": false,
                "error": "method must be one of: " & AllowedMethods.join(", ")}
    if timeout <= 0 or timeout > MaxTimeoutMs:
      return %*{"ok": false,
                "error": "timeout must be 1.." & $MaxTimeoutMs & " ms"}
    if maxSize < 1024 or maxSize > MaxSizeLimit:
      return %*{"ok": false,
                "error": "maxSize must be 1024.." & $MaxSizeLimit & " bytes"}

    try:
      let client = newHttpClient("niffler-fetch/0.1", timeout = timeout)
      defer: client.close()
      client.headers = newHttpHeaders({
        "User-Agent": "niffler-fetch/0.1",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5"})
      if headers != nil and headers.kind == JObject:
        for key, value in headers:
          client.headers[key] = value.getStr("")
      let requestMethod = case cleanMethod
        of "GET": HttpGet
        of "POST": HttpPost
        of "PUT": HttpPut
        of "DELETE": HttpDelete
        of "HEAD": HttpHead
        of "OPTIONS": HttpOptions
        of "PATCH": HttpPatch
        else: HttpGet
      let resp = if cleanMethod in ["POST", "PUT", "PATCH"]:
        client.request(url, requestMethod, body = body)
      else:
        client.request(url, requestMethod)

      var statusCode = 0
      try:
        statusCode = parseInt(resp.status.split()[0])
      except ValueError:
        discard
      if statusCode < 200 or statusCode >= 300:
        let cleanBody = resp.body.strip()
        let snippet = if cleanBody.len > 0:
          cleanBody[0 ..< min(cleanBody.len, MaxErrorSnippet)]
        else:
          ""
        let statusParts = resp.status.split(' ', 1)
        let reason = if statusParts.len > 1: statusParts[1].strip() else: ""
        return %*{"ok": false, "status": statusCode,
                  "error": "HTTP " & $statusCode &
                    (if reason.len > 0: " " & reason else: "") &
                    (if snippet.len > 0: " — " & snippet else: "")}

      if resp.body.len > maxSize:
        return %*{"ok": false, "status": statusCode,
                  "error": "response is " & $resp.body.len &
                    " bytes, over the " & $maxSize & " byte cap"}

      var contentType = ""
      if resp.headers.hasKey("Content-Type"):
        contentType = resp.headers["Content-Type"]
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
        filePath = saveToFile(content, url)
        savedToFile = true
        content = "Content saved to file (over " & $MaxInlineBytes &
          " bytes after processing): " & filePath &
          "\nOriginal URL: " & url
      %*{"ok": true, "url": url, "status": statusCode,
         "content": content, "contentType": contentType,
         "contentLength": resp.body.len, "convertedToText": convertedToText,
         "extractionMethod": extractionMethod, "savedToFile": savedToFile,
         "filePath": filePath}
    except CatchableError as e:
      return %*{"ok": false, "error": "fetch failed: " & e.msg}

comp.tools[^1].schema["x-harness"] = %*{"onDemand": true}

comp.run()
