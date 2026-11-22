package com.yutan123.skytide

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONObject
import java.io.IOException

fun main() {
    fun resolve(preset: String?, name: String = "", custom: Boolean = false, path: String = "/v1") =
        TideAiProtocol.resolve(preset, name, custom, "https://example.test$path".toHttpUrl())

    check(resolve(null, "ChatGPT") == TideAiProtocol.RESPONSES)
    check(resolve("Claude", path = "/v1/chat/completions/") == TideAiProtocol.COMPATIBLE)
    check(resolve("Gemini", custom = true) == TideAiProtocol.COMPATIBLE)
    check(resolve("Grok") == TideAiProtocol.COMPATIBLE)

    val request = TideAiClient.AiRequest(
        "https://example.test/gateway?tenant=one", "test", "model-id",
        listOf(TideAiClient.Message("system", "rules"), TideAiClient.Message("user", "hello")),
        allowSilence = true
    )
    val responses = TideAiProtocol.RESPONSES
    check(responses.endpoint(request).encodedPath == "/gateway/responses")
    check(JSONObject(TideAiClient.buildRequestBody(request, responses)).getJSONArray("input").length() == 2)
    val openAi = TideAiProtocol.Reply(responses)
    openAi.accept(JSONObject("""{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"hello"}]}],"usage":{"input_tokens":5,"output_tokens":3}}}"""), stream = true)
    check(openAi.terminated && openAi.text.toString() == "hello" && openAi.usage?.totalTokens == 8)

    val truncated = TideAiProtocol.Reply(responses)
    truncated.accept(JSONObject("""{"type":"response.incomplete","response":{"status":"completed","output":[{"type":"function_call","name":"choose_silence"}]}}"""), stream = true)
    check(truncated.terminated && truncated.finish == "length")
    check(runCatching { TideAiClient.finishReply("", truncated.tools, truncated.finish, null, true) }.exceptionOrNull() is IOException)

    val claude = TideAiProtocol.CLAUDE
    check(claude.endpoint(request).encodedPath == "/gateway/v1/messages")
    check(claude.headers("test")["anthropic-version"] == "2023-06-01")
    check(JSONObject(TideAiClient.buildRequestBody(request, claude)).getString("system") == "rules")
    val anthropic = TideAiProtocol.Reply(claude)
    listOf(
        """{"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":1}}}""",
        """{"type":"content_block_start","content_block":{"type":"tool_use","name":"choose_silence"}}""",
        """{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":4}}"""
    ).forEach { anthropic.accept(JSONObject(it), stream = true) }
    check(!anthropic.terminated)
    anthropic.accept(JSONObject("""{"type":"message_stop"}"""), stream = true)
    check(anthropic.terminated && anthropic.usage?.totalTokens == 16)
    check(TideAiClient.finishReply("", anthropic.tools, anthropic.finish, anthropic.usage, true).silent)
    check(runCatching { TideAiClient.finishReply("", anthropic.tools, anthropic.finish, null, false) }.exceptionOrNull() is IOException)

    val gemini = TideAiProtocol.GEMINI
    val url = gemini.endpoint(request)
    check(url.encodedPath == "/gateway/v1beta/models/model-id:streamGenerateContent")
    check(url.queryParameter("tenant") == "one" && url.queryParameter("alt") == "sse")
    check(gemini.headers("test") == mapOf("x-goog-api-key" to "test"))
    val google = TideAiProtocol.Reply(gemini)
    google.accept(JSONObject("""{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"functionCall":{"name":"choose_silence"}}]}}]}"""), stream = false)
    check(google.terminated)
    check(runCatching { TideAiClient.finishReply("", google.tools, google.finish, null, true) }.exceptionOrNull() is IOException)
}