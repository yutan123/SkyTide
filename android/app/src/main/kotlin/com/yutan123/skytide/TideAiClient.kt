package com.yutan123.skytide

import kotlinx.coroutines.*
import kotlin.coroutines.resume

import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * AI 客户端，使用 OkHttp 发送请求。
 * 支持流式/非流式响应、超时控制、重试机制。
 * 总超时 5 分钟（整个任务），不是每次重试 5 分钟。
 */
object TideAiClient {
    private const val TOTAL_TIMEOUT_MS = 5 * 60 * 1000L // 5 分钟
    private const val CONNECT_TIMEOUT_SEC = 30L
    private const val READ_TIMEOUT_SEC = 90L
    private const val MAX_RETRIES = 2

    data class AiRequest(
        val baseUrl: String,
        val apiKey: String,
        val model: String,
        val messages: List<Message>,
        val maxTokens: Int = 2000,
        val stream: Boolean = true,
        val allowSilence: Boolean = false,
        val presetName: String? = null,
        val providerName: String = "",
        val isCustom: Boolean = false
    )

    data class Message(
        val role: String,
        val content: String,
        val sentAt: Long = System.currentTimeMillis()
    )

    data class AiResponse(
        val content: String,
        val finishReason: String?,
        val usage: Usage?,
        val silent: Boolean = false
    )

    data class Usage(
        val promptTokens: Int,
        val completionTokens: Int,
        val totalTokens: Int
    )

    private val client = OkHttpClient.Builder()
        .connectTimeout(CONNECT_TIMEOUT_SEC, TimeUnit.SECONDS)
        .readTimeout(READ_TIMEOUT_SEC, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    private val nativeClient = client.newBuilder().followRedirects(false).build()

    private fun resolveProtocol(req: AiRequest) = TideAiProtocol.resolve(
        req.presetName, req.providerName, req.isCustom, req.baseUrl.trim().toHttpUrl())

    /**
     * 发送 AI 请求，支持重试。
     * 整个任务的总超时是 5 分钟，不是每次重试 5 分钟。
     */
    suspend fun sendRequest(
        request: AiRequest,
        onRequest: ((url: String, body: String, attempt: Int) -> Unit)? = null
    ): Result<AiResponse> = withContext(Dispatchers.IO) {
        try {
            withTimeout(TOTAL_TIMEOUT_MS) {
                var lastError: Throwable = IOException("Request failed")
                for (attempt in 0..MAX_RETRIES) {
                    ensureActive()
                    val result = doRequest(request, attempt + 1, onRequest)
                    if (result.isSuccess) return@withTimeout result
                    lastError = result.exceptionOrNull() ?: lastError
                    if (lastError is HttpException && !lastError.retryable) break
                    if (attempt < MAX_RETRIES) delay(1000L shl attempt)
                }
                Result.failure<AiResponse>(lastError)
            }
        } catch (e: TimeoutCancellationException) {
            currentCoroutineContext().ensureActive()
            Result.failure(TimeoutException("任务总超时 5 分钟已达到"))
        }
    }

    /**
     * 执行单次请求
     */
    private suspend fun doRequest(
        req: AiRequest,
        attempt: Int,
        onRequest: ((String, String, Int) -> Unit)?
    ): Result<AiResponse> {
        val protocol: TideAiProtocol
        val httpRequest: Request
        try {
            protocol = resolveProtocol(req)
            val url = protocol.endpoint(req)
            val body = buildRequestBody(req, protocol)
            runCatching { onRequest?.invoke(url.toString(), body, attempt) }
            httpRequest = Request.Builder()
                .url(url)
                .apply { protocol.headers(req.apiKey).forEach { (name, value) -> addHeader(name, value) } }
                .post(body.toRequestBody("application/json".toMediaType()))
                .build()
        } catch (e: IllegalArgumentException) {
            return Result.failure(e)
        }

        return suspendCancellableCoroutine { continuation ->
            val call = (if (protocol == TideAiProtocol.COMPATIBLE) client else nativeClient).newCall(httpRequest)
            continuation.invokeOnCancellation { call.cancel() }

            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    continuation.resume(Result.failure(e))
                }

                override fun onResponse(call: Call, response: Response) {
                    val result = try {
                        response.use {
                            if (!it.isSuccessful) Result.failure(HttpException(it.code))
                            else Result.success(parseResponse(it, protocol, req.allowSilence))
                        }
                    } catch (e: Exception) {
                        Result.failure<AiResponse>(e)
                    }
                    continuation.resume(result)
                }
            })
        }
    }

    /**
     * 构建请求体
     */
    internal fun buildRequestBody(req: AiRequest, protocol: TideAiProtocol = resolveProtocol(req)): String {
        val messages = JSONArray()
        req.messages.forEach { msg ->
            val msgObj = JSONObject()
            msgObj.put("role", msg.role)
            val time = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", java.util.Locale.US).format(java.util.Date(msg.sentAt))
            msgObj.put("content", if (msg.role == "user" || msg.role == "assistant") "[发送时间:$time]\n${msg.content}" else msg.content)
            messages.put(msgObj)
        }
        val function = JSONObject().put("name", "choose_silence").put("description", "不适合打扰时保持沉默")
            .put("parameters", JSONObject().put("type", "object").put("properties", JSONObject()))
        return protocol.payload(req, messages, function).toString()
    }

    private fun parseResponse(response: Response, protocol: TideAiProtocol, allowSilence: Boolean): AiResponse {
        val stream = response.header("Content-Type").orEmpty().contains("text/event-stream", ignoreCase = true)
        if (protocol == TideAiProtocol.COMPATIBLE) {
            return if (stream) parseStream(response, allowSilence)
            else parseChoice(readJson(response), allowSilence)
        }
        val reply = TideAiProtocol.Reply(protocol)
        if (stream) readEvents(response) { reply.accept(it, stream = true) }
        else reply.accept(readJson(response), stream = false)
        if (!reply.terminated) throw IOException("Truncated provider reply")
        return finishReply(reply.text.toString(), reply.tools, reply.finish, reply.usage, allowSilence)
    }

    private fun readJson(response: Response): JSONObject =
        JSONObject(response.body?.string() ?: throw IOException("Empty response"))

    private fun parseStream(response: Response, allowSilence: Boolean): AiResponse {
        val content = StringBuilder()
        val names = mutableMapOf<Int, StringBuilder>()
        var finish: String? = null
        var usage: Usage? = null
        readEvents(response) { json ->
            if (!json.isNull("error")) throw IOException("Provider stream error")
            json.optJSONObject("usage")?.let { usage = Usage(it.optInt("prompt_tokens"), it.optInt("completion_tokens"), it.optInt("total_tokens")) }
            val choice = json.optJSONArray("choices")?.optJSONObject(0) ?: return@readEvents
            if (!choice.isNull("finish_reason")) finish = choice.optString("finish_reason")
            val delta = choice.optJSONObject("delta") ?: choice.optJSONObject("message") ?: return@readEvents
            if (!delta.isNull("content")) content.append(delta.optString("content"))
            val tools = delta.optJSONArray("tool_calls") ?: JSONArray()
            for (i in 0 until tools.length()) {
                val tool = tools.getJSONObject(i)
                names.getOrPut(tool.optInt("index", i)) { StringBuilder() }
                    .append(tool.optJSONObject("function")?.optString("name").orEmpty())
            }
        }
        if (finish == null) throw IOException("Truncated stream")
        return finishReply(content.toString(), names.values.map { it.toString() }, finish, usage, allowSilence)
    }

    private fun readEvents(response: Response, accept: (JSONObject) -> Unit) {
        val source = response.body?.source() ?: throw IOException("Empty response")
        val data = StringBuilder()
        fun consume(): Boolean {
            val text = data.toString().trim()
            data.setLength(0)
            if (text == "[DONE]") return true
            if (text.isNotEmpty()) accept(JSONObject(text))
            return false
        }
        while (!source.exhausted()) {
            val line = source.readUtf8Line() ?: break
            if (line.isEmpty()) {
                if (consume()) return
            } else if (line.startsWith("data:")) {
                if (data.isNotEmpty()) data.append('\n')
                data.append(line.substring(5).trimStart())
            }
        }
        consume()
    }

    internal fun finishReply(text: String, tools: List<String>, finish: String?, usage: Usage?, allowSilence: Boolean): AiResponse {
        if (tools.isNotEmpty()) {
            if (!allowSilence || tools.any { it != "choose_silence" }) throw IOException("Unsupported tool")
            if (finish !in setOf("stop", "tool_calls", "function_call", "tool_use", "STOP")) {
                throw IOException("Unfinished tool response")
            }
            return AiResponse("", finish, usage, silent = true)
        }
        val visible = stripMetadata(text)
        if (visible.isBlank()) throw IOException("Empty reply")
        return AiResponse(visible, finish, usage)
    }

    private fun parseChoice(json: JSONObject, allowSilence: Boolean): AiResponse {
        val choices = json.optJSONArray("choices")
            ?: throw IOException("No choices in response")

        if (choices.length() == 0) {
            throw IOException("Empty choices array")
        }

        val choice = choices.getJSONObject(0)
        val message = choice.optJSONObject("message")
            ?: choice.optJSONObject("delta")
            ?: throw IOException("No message/delta in choice")

        val calls = message.optJSONArray("tool_calls") ?: JSONArray()
        val tools = (0 until calls.length()).map {
            calls.getJSONObject(it).optJSONObject("function")?.optString("name").orEmpty()
        }
        val content = if (message.isNull("content")) "" else message.optString("content")
        val finishReason = choice.optString("finish_reason").takeUnless { choice.isNull("finish_reason") }
        val usage = json.optJSONObject("usage")?.let {
            Usage(it.optInt("prompt_tokens"), it.optInt("completion_tokens"), it.optInt("total_tokens"))
        }
        return finishReply(content, tools, finishReason, usage, allowSilence)
    }

    // Text that imitates a tool call must never be stored as a chat message.
    // This does not set silent: only a real tool_calls entry can do that.
    private fun stripMetadata(text: String): String = text.replace(
        Regex("""\[\s*tool_call\s+[a-z_][a-z0-9_]*\s*\]""", RegexOption.IGNORE_CASE), "")
        .replace(Regex("""\[(?:(?:你|对方)发送了一个表情包，表情包类型|发送时间)\s*[:：][^\]]*(?:\]|$)"""), "").trim()

    private class HttpException(code: Int) : IOException("Provider HTTP $code") {
        val retryable = code == 408 || code == 429 || code >= 500
    }

    class TimeoutException(message: String) : IOException(message)
}