## Conversation condensation module
## Provides LLM-based summarization to create condensed child conversations

import std/[options, times, json, strformat]
import sunny
import ../types/[messages, config as configTypes]
import conversation_manager
import database
import app
import ../api/api
import ../api/curlyStreaming
import ../tools/registry
import system_prompt
import session
import mode_state
import logging

type
  CondensationStrategy* = enum
    csLlmSummary = "llm_summary"
    csTruncate = "truncate"
    csSmartWindow = "smart_window"

  CondensationResult* = object
    success*: bool
    newConversationId*: int
    summary*: string
    originalMessageCount*: int
    errorMessage*: string

const SUMMARIZATION_PROMPT = """
Analyze this Niffler conversation and create a concise markdown summary that can serve as the first message in a new condensed conversation.

Your summary should:
1. Extract the main objectives and what was accomplished
2. List any files that were created or modified (artifacts)
3. Summarize key tool usage and outcomes
4. Note any errors, issues, or blockers encountered
5. Suggest logical next steps if applicable

Format the summary as markdown that reads naturally as a continuation prompt. Do not include meta-commentary about the conversation itself - focus on the actual content and work done.

The summary should be comprehensive enough that someone continuing the conversation would have full context, but concise enough to save significant tokens.

Here is the conversation to summarize (in OpenAI API request format):
"""

proc generateConversationSummary*(model: configTypes.ModelConfig, messages: seq[Message], toolSchemas: seq[ToolDefinition]): string =
  ## Generate an LLM summary of the conversation using the /inspect JSON format
  try:
    # Create the chat request (similar to /inspect command)
    let chatRequest = createChatRequest(model, messages, false, some(toolSchemas))
    let conversationJson = toJson(chatRequest).pretty(indent = 2)

    # Build summarization request
    let summaryMessages = @[
      Message(role: mrUser, content: SUMMARIZATION_PROMPT & "\n\n```json\n" & conversationJson & "\n```")
    ]

    # Create request for summarization (no tools needed for this)
    let summaryRequest = createChatRequest(model, summaryMessages, false, none(seq[ToolDefinition]))

    # Send to LLM and get summary using streaming client
    debug("Sending conversation to LLM for summarization")
    var client = CurlyStreamingClient(
      baseUrl: model.baseUrl,
      apiKey: model.apiKey.get(""),
      model: model.model
    )

    var accumulatedContent = ""
    let (success, _) = client.sendStreamingChatRequest(summaryRequest, proc(chunk: StreamChunk) =
      if chunk.choices.len > 0 and chunk.choices[0].delta.content.len > 0:
        accumulatedContent &= chunk.choices[0].delta.content
    )

    if success and accumulatedContent.len > 0:
      result = accumulatedContent
      debug(fmt("Generated summary: {result.len} characters"))
    else:
      error("Failed to generate summary from LLM")
      result = ""

  except Exception as e:
    error(fmt("Exception during summarization: {e.msg}"))
    result = ""

proc createCondensedConversation*(backend: DatabaseBackend,
                                  strategy: CondensationStrategy,
                                  model: configTypes.ModelConfig): CondensationResult =
  ## Create a condensed conversation from the current conversation
  ## Returns the new conversation ID and summary
  result = CondensationResult(success: false)

  try:
    # Get current conversation context
    let currentConvId = getCurrentConversationId()
    if currentConvId <= 0:
      result.errorMessage = "No active conversation to condense"
      return

    # Get messages and truncate if needed
    var messages = getConversationContext()
    result.originalMessageCount = messages.len

    if messages.len == 0:
      result.errorMessage = "Cannot condense empty conversation"
      return

    messages = truncateContextIfNeeded(messages)

    # Add system message at the beginning (needed for context)
    let sess = initSession()
    let currentMode = getCurrentMode()
    let (systemMsg, _) = createSystemMessageWithTokens(currentMode, sess, model.nickname)
    messages.insert(systemMsg, 0)

    # Get tool schemas
    let toolSchemas = getAllToolSchemas()

    # Generate summary based on strategy
    var summary: string
    case strategy:
    of csLlmSummary:
      summary = generateConversationSummary(model, messages, toolSchemas)
      if summary.len == 0:
        result.errorMessage = "Failed to generate LLM summary"
        return
    of csTruncate:
      # Simple truncation - just use last N messages
      result.errorMessage = "Truncate strategy not yet implemented"
      return
    of csSmartWindow:
      # Keep first N + last M messages
      result.errorMessage = "Smart window strategy not yet implemented"
      return

    # Create new conversation
    let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
    let newTitle = fmt("Condensed from conversation {currentConvId} ({timestamp})")
    let newConvOpt = createConversation(backend, newTitle, currentMode, model.nickname)

    if newConvOpt.isNone:
      result.errorMessage = "Failed to create new conversation"
      return

    let newConv = newConvOpt.get()
    result.newConversationId = newConv.id

    # Switch to new conversation
    let switchResult = switchToConversation(backend, newConv.id)
    if not switchResult:
      result.errorMessage = fmt("Created conversation {newConv.id} but failed to switch to it")
      return

    # Add summary as first user message
    discard addUserMessage(summary)

    # Update new conversation with parent link and condensation metadata
    let metadataJson = %*{
      "condensed_at": timestamp,
      "original_conversation_id": currentConvId,
      "original_message_count": result.originalMessageCount,
      "strategy": $strategy,
      "summary_length": summary.len
    }

    let updateSuccess = setConversationCondensationInfo(
      backend,
      newConv.id,
      currentConvId,
      result.originalMessageCount,
      $strategy,
      $metadataJson
    )

    if not updateSuccess:
      warn("Failed to update condensation metadata, but conversation was created")

    result.success = true
    result.summary = summary
    debug(fmt("Successfully created condensed conversation {newConv.id} from {currentConvId}"))

  except Exception as e:
    error(fmt("Failed to condense conversation: {e.msg}"))
    result.errorMessage = e.msg
    result.success = false

# Helper functions for getting condensation info can be added later if needed
