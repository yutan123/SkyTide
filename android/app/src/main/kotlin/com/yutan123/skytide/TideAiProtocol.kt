package com.yutan123.skytide

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException

internal enum class TideAiProtocol {
    COMPATIBLE, RESPONSES, CLAUDE, GEMINI;

    companion object {
        fun resolve(preset: String?, name: String, custom: Boolean, configured: HttpUrl): TideAiProtocol {
            if (custom) return COMPATIBLE
            if (preset == "Claude" || preset == "Gemini") {
                if (configured.encodedPath.trimEnd('/').endsWith("/chat/completions")) return COMPATIBLE
                return if (preset == "Claude") CLAUDE else GEMINI
            }
            return if ((preset ?: name) == "ChatGPT") RESPONSES else COMPATIBLE
        }
    }

    fun endpoint(req: TideAiClient.AiRequest): HttpUrl {
        val base = req.baseUrl.trim().toHttpUrl()
        var path = base.encodedPath.trimEnd('/')
        val builder = base.newBuilder().fragment(null)
        when (this) {
            COMPATIBLE, RESPONSES -> {
                val suffix = if (this == COMPATIBLE) "/chat/completions" else "/responses"
                if (path.endsWith(suffix)) return builder.encodedPath(path).build()
                path = path.replace(Regex("/(chat/completions|responses|chat)$"), "").ifEmpty { "/v1" }
                builder.encodedPath(path + suffix)
            }
            CLAUDE, GEMINI -> {
                path = if (this == CLAUDE) path.removeSuffix("/messages") else
                    path.replace(Regex("/models/[^/]+:(streamGenerateContent|generateContent)$"), "")
                path = path.removeSuffix("/models")
                if (!Regex("/v[0-9]+(?:(?:alpha|beta)[0-9]*)?$").containsMatchIn(path)) {
                    path += if (this == CLAUDE) "/v1" else "/v1beta"
                }
                if (this == CLAUDE) builder.encodedPath("$path/messages")
                else {
                    val method = if (req.stream) "streamGenerateContent" else "generateContent"
                    builder.encodedPath("$path/models/")
                        .addPathSegment("${req.model.removePrefix("models/")}:$method")
                    if (req.stream) builder.setQueryParameter("alt", "sse")
                }
            }
        }
        return builder.build()
    }

    fun headers(key: String): Map<String, String> = when (this) {
        COMPATIBLE, RESPONSES -> mapOf("Authorization" to "Bearer $key")
        CLAUDE -> mapOf("x-api-key" to key, "anthropic-version" to "2023-06-01")
        GEMINI -> mapOf("x-goog-api-key" to key)
    }

    fun payload(req: TideAiClient.AiRequest, messages: JSONArray, function: JSONObject): JSONObject {
        val body = JSONObject()
        val conversation = JSONArray()
        val systems = mutableListOf<String>()
        if (this == COMPATIBLE) {
            body.put("model", req.model).put("max_tokens", req.maxTokens)
                .put("stream", req.stream).put("messages", messages)
            if (req.allowSilence) body.put("tools", JSONArray().put(JSONObject()
                .put("type", "function").put("function", function)))
            return body
        }
        for (message in objects(messages)) {
            val role = message.getString("role")
            val text = message.getString("content")
            when {
                this == RESPONSES -> conversation.put(message)
                role == "system" -> systems.add(text)
                this == CLAUDE -> conversation.put(message)
                else -> conversation.put(JSONObject().put("role", if (role == "assistant") "model" else "user")
                    .put("parts", JSONArray().put(JSONObject().put("text", text))))
            }
        }
        if (this != GEMINI) body.put("model", req.model).put("stream", req.stream)
        val tools = JSONArray()
        val name = function.getString("name")
        val description = function.getString("description")
        val schema = function.getJSONObject("parameters")
        when (this) {
            RESPONSES -> {
                body.put("input", conversation).put("store", false).put("max_output_tokens", req.maxTokens)
                tools.put(function.put("type", "function").put("strict", false))
            }
            CLAUDE -> {
                body.put("messages", conversation).put("max_tokens", req.maxTokens)
                if (systems.isNotEmpty()) body.put("system", systems.joinToString("\n\n"))
                tools.put(JSONObject().put("name", name).put("description", description).put("input_schema", schema))
            }
            GEMINI -> {
                body.put("contents", conversation).put("generationConfig",
                    JSONObject().put("maxOutputTokens", req.maxTokens.coerceIn(1, 8192)))
                if (systems.isNotEmpty()) body.put("systemInstruction", JSONObject().put("parts",
                    JSONArray().put(JSONObject().put("text", systems.joinToString("\n\n")))))
                tools.put(JSONObject().put("functionDeclarations", JSONArray().put(JSONObject()
                    .put("name", name).put("description", description))))
            }
            COMPATIBLE -> error("Compatible payload already handled")
        }
        if (req.allowSilence) body.put("tools", tools)
        return body
    }

    internal class Reply(private val protocol: TideAiProtocol) {
        val text = StringBuilder()
        val tools = mutableListOf<String>()
        var finish: String? = null
            private set
        var terminated = false
            private set
        private var input = 0
        private var output = 0
        private var total: Int? = null
        private var hasUsage = false
        val usage: TideAiClient.Usage?
            get() = if (hasUsage) TideAiClient.Usage(input, output, total ?: (input + output)) else null

        private fun usage(json: JSONObject?, inputKey: String, outputKey: String, totalKey: String) {
            if (json == null) return
            hasUsage = true
            input = json.optInt(inputKey, input)
            output = json.optInt(outputKey, output)
            if (!json.isNull(totalKey)) total = json.optInt(totalKey)
        }

        private fun claudeBlock(block: JSONObject) {
            when (block.optString("type")) {
                "text" -> text.append(block.optString("text"))
                "tool_use" -> tools.add(block.optString("name"))
            }
        }

        private fun claudeUsage(event: JSONObject) = usage(event.optJSONObject("usage"),
            "input_tokens", "output_tokens", "total_tokens")

        fun accept(event: JSONObject, stream: Boolean) {
            val type = event.optString("type")
            if (!event.isNull("error") || type == "error" || type == "response.failed") {
                throw IOException("Provider response error")
            }
            when (protocol) {
                RESPONSES -> {
                    if (stream && type != "response.completed" && type != "response.incomplete") return
                    val result = if (stream) event.getJSONObject("response") else event
                    val status = result.optString("status")
                    val incomplete = type == "response.incomplete" || status == "incomplete"
                    if (!incomplete && status != "completed") throw IOException("Unfinished Responses reply")
                    for (item in objects(result.optJSONArray("output"))) {
                        when (item.optString("type")) {
                            "function_call" -> tools.add(item.optString("name"))
                            "message" -> for (part in objects(item.optJSONArray("content"))) {
                                if (part.optString("type") == "output_text") text.append(part.optString("text"))
                            }
                        }
                    }
                    usage(result.optJSONObject("usage"), "input_tokens", "output_tokens", "total_tokens")
                    finish = if (incomplete) "length" else if (tools.isEmpty()) "stop" else "tool_calls"
                    terminated = true
                }
                CLAUDE -> {
                    if (!stream) {
                        objects(event.optJSONArray("content")).forEach(::claudeBlock)
                        claudeUsage(event)
                        finish = event.optString("stop_reason").takeIf { !event.isNull("stop_reason") }
                        terminated = finish != null
                    } else when (type) {
                        "message_start" -> event.optJSONObject("message")?.let(::claudeUsage)
                        "content_block_start" -> event.optJSONObject("content_block")?.let(::claudeBlock)
                        "content_block_delta" -> event.optJSONObject("delta")?.let {
                            if (it.optString("type") == "text_delta") text.append(it.optString("text"))
                        }
                        "message_delta" -> {
                            claudeUsage(event)
                            event.optJSONObject("delta")?.let {
                                if (!it.isNull("stop_reason")) finish = it.optString("stop_reason")
                            }
                        }
                        "message_stop" -> terminated = finish != null
                    }
                }
                GEMINI -> {
                    usage(event.optJSONObject("usageMetadata"), "promptTokenCount", "candidatesTokenCount", "totalTokenCount")
                    val candidate = event.optJSONArray("candidates")?.optJSONObject(0) ?: return
                    for (part in objects(candidate.optJSONObject("content")?.optJSONArray("parts"))) {
                        if (!part.optBoolean("thought")) {
                            if (!part.isNull("text")) text.append(part.optString("text"))
                            part.optJSONObject("functionCall")?.let { tools.add(it.optString("name")) }
                        }
                    }
                    val reason = candidate.optString("finishReason").takeUnless { candidate.isNull("finishReason") }
                    if (!reason.isNullOrEmpty() && reason != "FINISH_REASON_UNSPECIFIED") {
                        finish = reason
                        terminated = true
                    }
                }
                COMPATIBLE -> error("Compatible replies use the Chat Completions parser")
            }
        }
    }
}

private fun objects(array: JSONArray?): Sequence<JSONObject> = sequence {
    if (array != null) for (i in 0 until array.length()) yield(array.getJSONObject(i))
}
