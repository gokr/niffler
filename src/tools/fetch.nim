## Web Fetch Tool
##
## This tool provides secure web content fetching with:
## - HTTP/HTTPS URL support with timeout protection
## - HTML to text conversion for readable content
## - Content type detection and handling
## - User agent specification and header management
## - Response size limits for safety
##
## Features:
## - Clean HTML to text conversion with proper formatting
## - HTTP client with configurable timeout
## - URL validation and sanitization
## - Error handling for network issues and invalid responses
## - Support for redirects and various content types

import std/[strutils, json, httpclient, uri, xmltree, strformat]
import pkg/htmlparser
import ../types/tools
import ../types/tool_args
import ../core/constants
import text_extraction


proc htmlToText*(html: string): string =
  ## Convert HTML content to plain text with proper formatting and spacing
  try:
    let xml = parseHtml(html)
    var textResult = ""
    
    proc extractText(node: XmlNode, text: var string) =
      if node.kind == xnText:
        text.add(node.text & " ")
      elif node.kind == xnElement:
        for child in node:
          extractText(child, text)
        # Add spacing after block elements
        if node.tag.toLowerAscii() in ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "br"]:
          text.add("\n")
    
    extractText(xml, textResult)
    result = textResult.strip()
    # Clean up excessive whitespace
    result = result.multiReplace(("\n\n\n", "\n\n"), ("  ", " "))
  except:
    return "Failed to parse HTML content"

proc createHttpClient*(timeout: int): HttpClient =
  ## Create HTTP client with specified timeout and appropriate headers
  result = newHttpClient(timeout = timeout)
  result.headers = newHttpHeaders({
    "User-Agent": "Niffler/1.0",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.5"
  })

proc addCustomHeaders*(client: var HttpClient, headers: JsonNode) =
  ## Add custom headers to HTTP client
  if headers.kind == JObject:
    for key, value in headers:
      client.headers[key] = value.getStr()

proc executeFetch*(args: JsonNode): string {.gcsafe.} =
  ## Execute fetch HTTP/HTTPS content operation
  var parsedArgs = parseWithDefaults(FetchArgs, args, "fetch")

  # Validate URL
  if parsedArgs.url.len == 0:
    raise newToolValidationError("fetch", "url", "non-empty string", "empty string")

  try:
    let parsedUri = parseUri(parsedArgs.url)
    if parsedUri.scheme notin ["http", "https"]:
      raise newToolValidationError("fetch", "url", "HTTP/HTTPS URL", parsedArgs.url)
  except:
    raise newToolValidationError("fetch", "url", "valid URL", parsedArgs.url)

  # Validate timeout
  if parsedArgs.timeout <= 0:
    raise newToolValidationError("fetch", "timeout", "positive integer", $parsedArgs.timeout)

  if parsedArgs.timeout > MAX_TIMEOUT:
    raise newToolValidationError("fetch", "timeout", fmt"timeout under {MAX_TIMEOUT}ms", $parsedArgs.timeout)

  # Validate max_size
  if parsedArgs.maxSize <= 0:
    raise newToolValidationError("fetch", "max_size", "positive integer", $parsedArgs.maxSize)

  if parsedArgs.maxSize > MAX_FETCH_SIZE_LIMIT:
    raise newToolValidationError("fetch", "max_size", fmt"size under {MAX_FETCH_SIZE_LIMIT} bytes", $parsedArgs.maxSize)

  # Validate method
  let validMethods = ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"]
  if parsedArgs.`method`.toUpperAscii() notin validMethods:
    raise newToolValidationError("fetch", "method", "one of: " & validMethods.join(", "), parsedArgs.`method`)
  
  try:
    # Create HTTP client
    var client = createHttpClient(parsedArgs.timeout)
    addCustomHeaders(client, parsedArgs.headers)

    # Make request
    var response: Response
    let requestMethod = case parsedArgs.`method`.toUpperAscii():
      of "GET": HttpGet
      of "POST": HttpPost
      of "PUT": HttpPut
      of "DELETE": HttpDelete
      of "HEAD": HttpHead
      of "OPTIONS": HttpOptions
      of "PATCH": HttpPatch
      else: HttpGet

    if parsedArgs.`method`.toUpperAscii() in ["POST", "PUT", "PATCH"]:
      response = client.request(parsedArgs.url, requestMethod, body = parsedArgs.body)
    else:
      response = client.request(parsedArgs.url, requestMethod)

    # Check response size
    if response.body.len > parsedArgs.maxSize:
      raise newToolExecutionError("fetch", "Response size exceeds limit: " & $response.body.len & " > " & $parsedArgs.maxSize, -1, "")
    
    # Convert HTML to text if requested
    var content = response.body
    var contentType = "text/plain"

    if response.headers.hasKey("Content-Type"):
      contentType = response.headers["Content-Type"]

    var convertedToText = false
    var extractionMethod = "none"
    if parsedArgs.convertToText and contentType.toLowerAscii().contains("text/html"):
      let textExtConfig = getCurrentTextExtractionConfig()
      let extractionResult = extractText(response.body, parsedArgs.url, textExtConfig)

      if extractionResult.success:
        content = extractionResult.content
        convertedToText = true
        extractionMethod = if extractionResult.usedExternal: "external" else: "builtin"
      else:
        content = htmlToText(response.body)
        convertedToText = true
        extractionMethod = "builtin-fallback"
    
    # Create result
    let resultJson = %*{
      "url": parsedArgs.url,
      "status_code": response.status,
      "content": content,
      "content_type": contentType,
      "content_length": response.body.len,
      "headers": %*{},
      "converted_to_text": convertedToText,
      "extraction_method": extractionMethod,
      "method": parsedArgs.`method`,
      "timeout": parsedArgs.timeout,
      "max_size": parsedArgs.maxSize
    }
    
    return $resultJson
  
  except ToolError as e:
    raise e
  except:
    let errorMsg = getCurrentExceptionMsg()
    raise newToolExecutionError("fetch", "Failed to fetch URL: " & errorMsg, -1, "")