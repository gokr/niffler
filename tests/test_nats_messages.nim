import std/[unittest, json, times, strutils]
import ../src/types/nats_messages

suite "NATS Message Serialization":
  test "NatsRequest serialization and deserialization":
    let req = createRequest("req-123", "coder", "/plan Create a new feature")

    check req.requestId == "req-123"
    check req.agentName == "coder"
    check req.input == "/plan Create a new feature"

    # Serialize to JSON string
    let jsonStr = $req
    let jsonNode = parseJson(jsonStr)
    check jsonNode["request_id"].getStr() == "req-123"
    check jsonNode["agent_name"].getStr() == "coder"
    check jsonNode["input"].getStr() == "/plan Create a new feature"

    # Deserialize back
    let req2 = fromJson(NatsRequest, jsonStr)
    check req2.requestId == req.requestId
    check req2.agentName == req.agentName
    check req2.input == req.input

  test "NatsResponse serialization and deserialization":
    let resp = createResponse("req-123", "test-agent", "Here is the plan...", done = false)

    check resp.requestId == "req-123"
    check resp.content == "Here is the plan..."
    check resp.done == false

    # Serialize to JSON string
    let jsonStr = $resp
    let jsonNode = parseJson(jsonStr)
    check jsonNode["request_id"].getStr() == "req-123"
    check jsonNode["content"].getStr() == "Here is the plan..."
    check jsonNode["done"].getBool() == false

    # Deserialize back
    let resp2 = fromJson(NatsResponse, jsonStr)
    check resp2.requestId == resp.requestId
    check resp2.content == resp.content
    check resp2.done == resp.done

  test "NatsResponse with done flag":
    let resp = createResponse("req-456", "test-agent", "Final response", done = true)

    check resp.done == true

    let jsonStr = $resp
    let jsonNode = parseJson(jsonStr)
    check jsonNode["done"].getBool() == true

  test "NatsStatusUpdate serialization and deserialization":
    let update = createStatusUpdate("req-789", "coder", "Switching to plan mode")

    check update.requestId == "req-789"
    check update.agentName == "coder"
    check update.status == "Switching to plan mode"

    # Serialize to JSON string
    let jsonStr = $update
    let jsonNode = parseJson(jsonStr)
    check jsonNode["request_id"].getStr() == "req-789"
    check jsonNode["agent_name"].getStr() == "coder"
    check jsonNode["status"].getStr() == "Switching to plan mode"

    # Deserialize back
    let update2 = fromJson(NatsStatusUpdate, jsonStr)
    check update2.requestId == update.requestId
    check update2.agentName == update.agentName
    check update2.status == update.status

  test "NatsHeartbeat serialization and deserialization":
    let hb = createHeartbeat("coder")

    check hb.agentName == "coder"
    check hb.timestamp > 0

    # Serialize to JSON string
    let jsonStr = $hb
    let jsonNode = parseJson(jsonStr)
    check jsonNode["agent_name"].getStr() == "coder"
    check jsonNode["timestamp"].getInt() > 0

    # Deserialize back
    let hb2 = fromJson(NatsHeartbeat, jsonStr)
    check hb2.agentName == hb.agentName
    check hb2.timestamp == hb.timestamp

  test "NatsHeartbeat has current timestamp":
    let before = getTime().toUnix()
    let hb = createHeartbeat("test-agent")
    let after = getTime().toUnix()

    check hb.timestamp >= before
    check hb.timestamp <= after

  test "String conversion works for all message types":
    let req = createRequest("r1", "agent1", "test")
    let resp = createResponse("r1", "agent1", "result", done = true)
    let update = createStatusUpdate("r1", "agent1", "ready")
    let hb = createHeartbeat("agent1")

    # Should not crash and should produce valid JSON strings
    let reqStr = $req
    let respStr = $resp
    let updateStr = $update
    let hbStr = $hb

    check reqStr.len > 0
    check respStr.len > 0
    check updateStr.len > 0
    check hbStr.len > 0

    # Should be parseable as JSON
    discard parseJson(reqStr)
    discard parseJson(respStr)
    discard parseJson(updateStr)
    discard parseJson(hbStr)

  test "Round-trip serialization preserves data":
    # Request
    let req = createRequest("id1", "coder", "/model gpt-4 Write tests")
    let reqJson = $req
    let req2 = fromJson(NatsRequest, reqJson)
    check req2.requestId == req.requestId
    check req2.agentName == req.agentName
    check req2.input == req.input

    # Response
    let resp = createResponse("id2", "test-agent", "Content here", done = false)
    let respJson = $resp
    let resp2 = fromJson(NatsResponse, respJson)
    check resp2.requestId == resp.requestId
    check resp2.content == resp.content
    check resp2.done == resp.done

    # Status update
    let update = createStatusUpdate("id3", "planner", "Planning...")
    let updateJson = $update
    let update2 = fromJson(NatsStatusUpdate, updateJson)
    check update2.requestId == update.requestId
    check update2.agentName == update.agentName
    check update2.status == update.status

    # Heartbeat
    let hb = createHeartbeat("worker")
    let hbJson = $hb
    let hb2 = fromJson(NatsHeartbeat, hbJson)
    check hb2.agentName == hb.agentName
    check hb2.timestamp == hb.timestamp

  test "Message types handle special characters":
    let req = createRequest("id-with-dashes", "agent-name", "/plan \"quoted\" 'string' with\nnewlines")
    let jsonStr = $req
    let req2 = fromJson(NatsRequest, jsonStr)

    check req2.input == req.input
    check req2.input.contains("\"quoted\"")
    check req2.input.contains("'string'")
    check req2.input.contains("\n")

  test "Empty content is preserved":
    let resp = createResponse("id1", "test-agent", "", done = true)
    let jsonStr = $resp
    let resp2 = fromJson(NatsResponse, jsonStr)

    check resp2.content == ""
    check resp2.content.len == 0
