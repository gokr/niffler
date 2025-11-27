import test_conversation_infrastructure

let testDb = createTestDatabase()
setGlobalDatabase(testDb.backend)

echo "Initial conversation count: ", listConversations(testDb.backend).len

let convId = createTestConversationWithMessages(testDb.backend, "Debug Conversation", 3)
echo "Created conversation ID: ", convId

let conversations = listConversations(testDb.backend)
echo "After creation count: ", conversations.len
echo "Conversation titles: ", conversations.mapIt(it.title)

cleanupTestDatabase(testDb)
