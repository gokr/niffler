## Shared agent dispatch transport over NATS

import std/[strformat, times, random, options, strutils]
import nats_client
import ../types/nats_messages

type
  PreparedAgentRequest* = object
    requestId*: string
    subject*: string
    payload*: string
    agentName*: string
    input*: string

  PreparedAgentRequestResult* = object
    success*: bool
    request*: PreparedAgentRequest
    error*: string

proc generateAgentRequestId*(): string =
  ## Generate a unique request ID for NATS agent dispatch
  let timestamp = getTime().toUnix()
  let randomVal = rand(999999)
  result = fmt("{timestamp}-{randomVal}")

proc prepareAgentRequest*(client: NifflerNatsClient, agentName: string, input: string,
                         requestId: string = ""): PreparedAgentRequestResult =
  ## Prepare a validated request for an agent over NATS
  if agentName.len == 0:
    return PreparedAgentRequestResult(success: false, error: "Agent name is required")

  if client.kv != nil and not client.isPresent(agentName):
    return PreparedAgentRequestResult(success: false, error: fmt("Agent '{agentName}' is not available"))

  let effectiveRequestId = if requestId.len > 0: requestId else: generateAgentRequestId()
  let request = createRequest(effectiveRequestId, agentName, input)

  PreparedAgentRequestResult(
    success: true,
    request: PreparedAgentRequest(
      requestId: effectiveRequestId,
      subject: fmt("niffler.agent.{agentName}.request"),
      payload: $request,
      agentName: agentName,
      input: input
    )
  )

proc publishAgentRequest*(client: NifflerNatsClient, request: PreparedAgentRequest) =
  ## Publish a prepared agent request
  client.publish(request.subject, request.payload)

proc collectAgentResult*(client: NifflerNatsClient, requestId: string,
                        timeoutSec: int = 120): tuple[success: bool, message: string, status: string] =
  ## Collect the terminal response for a dispatched agent request
  var responseSub = client.subscribe("niffler.master.response")
  var statusSub = client.subscribe("niffler.master.status")

  try:
    var responseChunks: seq[string] = @[]
    var latestStatus = ""
    let deadline = getTime() + initDuration(seconds = timeoutSec)

    while getTime() < deadline:
      let maybeStatus = statusSub.nextMsg(250)
      if maybeStatus.isSome():
        try:
          let update = fromJson(NatsStatusUpdate, maybeStatus.get().data)
          if update.requestId == requestId:
            latestStatus = update.status
        except CatchableError:
          discard

      let maybeResponse = responseSub.nextMsg(250)
      if maybeResponse.isSome():
        try:
          let response = fromJson(NatsResponse, maybeResponse.get().data)
          if response.requestId != requestId:
            continue

          if response.content.len > 0:
            responseChunks.add(response.content)

          if response.done:
            let finalMessage = if responseChunks.len > 0:
              responseChunks.join("\n")
            elif latestStatus.len > 0:
              latestStatus
            else:
              "Request completed without response content."
            return (true, finalMessage, latestStatus)
        except CatchableError:
          discard

    let timeoutMessage = if latestStatus.len > 0:
      fmt("Timed out waiting for request {requestId}. Last status: {latestStatus}")
    else:
      fmt("Timed out waiting for request {requestId}.")
    return (false, timeoutMessage, latestStatus)
  finally:
    responseSub.unsubscribe()
    statusSub.unsubscribe()
