-- Check the most recent conversation and its messages
-- Usage: mysql -h 127.0.0.1 -P 4000 -u root niffler < check_conversation.sql

-- Show latest conversation
SELECT '=== Latest Conversation ===' as '';
SELECT id, title, model, created_at, updated_at
FROM conversation
ORDER BY created_at DESC
LIMIT 1;

-- Get the conversation ID
SET @conv_id = (SELECT id FROM conversation ORDER BY created_at DESC LIMIT 1);

-- Show message summary
SELECT '' as '';
SELECT '=== Message Summary ===' as '';
SELECT
    role,
    COUNT(*) as message_count,
    SUM(LENGTH(content)) as total_chars,
    SUM(COALESCE(output_tokens, 0)) as total_output_tokens
FROM conversation_message
WHERE conversation_id = @conv_id
GROUP BY role
ORDER BY
    CASE role
        WHEN 'system' THEN 1
        WHEN 'user' THEN 2
        WHEN 'assistant' THEN 3
        WHEN 'tool' THEN 4
    END;

-- Show all messages with preview
SELECT '' as '';
SELECT '=== All Messages ===' as '';
SELECT
    id,
    role,
    LEFT(content, 80) as content_preview,
    output_tokens,
    created_at
FROM conversation_message
WHERE conversation_id = @conv_id
ORDER BY created_at;

-- Show assistant responses in detail
SELECT '' as '';
SELECT '=== Assistant Responses (full) ===' as '';
SELECT
    id,
    role,
    content,
    output_tokens,
    created_at
FROM conversation_message
WHERE conversation_id = @conv_id AND role = 'assistant'
ORDER BY created_at;

-- Show token usage if available
SELECT '' as '';
SELECT '=== Token Usage ===' as '';
SELECT
    created_at,
    model,
    input_tokens,
    output_tokens,
    total_cost
FROM model_token_usage
WHERE created_at >= (SELECT created_at FROM conversation WHERE id = @conv_id)
ORDER BY created_at DESC
LIMIT 5;
