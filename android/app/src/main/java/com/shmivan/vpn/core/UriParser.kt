package com.shmivan.vpn.core

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder

/** Turns 3x-ui / v2rayN share links into Xray outbound objects (same rules as the macOS app). */
object UriParser {
    private val schemes = setOf("vless", "http", "https", "socks", "socks5")

    fun links(text: String): List<String> = text.lines().mapNotNull { raw ->
        var line = raw.trim()
        val eq = line.indexOf('=')
        if (eq > 0 && !line.substring(0, eq).contains(':')) line = line.substring(eq + 1)  // KEY=vless://…
        line = line.trim('"', '\'', ' ')
        val scheme = line.substringBefore(':').lowercase()
        line.takeIf { scheme in schemes && it.contains("://") }
    }

    fun displayName(uri: String): String = runCatching {
        val u = URI(uri)
        u.rawFragment?.let { decode(it) }?.takeIf { it.isNotEmpty() } ?: u.host
    }.getOrNull() ?: "Server"

    fun host(uri: String): String? = runCatching { URI(uri).host?.removeSurrounding("[", "]") }.getOrNull()

    fun outbound(uri: String, tag: String): JSONObject {
        val u = URI(uri)
        return when (val scheme = u.scheme?.lowercase()) {
            "vless" -> vless(u, tag)
            "http", "https", "socks", "socks5" -> plainProxy(u, scheme, tag)
            else -> throw IllegalArgumentException("Unsupported link type: $scheme")
        }
    }

    private fun vless(u: URI, tag: String): JSONObject {
        val id = u.rawUserInfo?.let(::decode)?.takeIf { it.isNotEmpty() } ?: error("missing UUID")
        val host = u.host?.removeSurrounding("[", "]")?.takeIf { it.isNotEmpty() } ?: error("missing host")
        val q = query(u)
        val user = JSONObject().put("id", id).put("encryption", q["encryption"] ?: "none")
        q["flow"]?.takeIf { it.isNotEmpty() }?.let { user.put("flow", it) }
        val server = JSONObject().put("address", host).put("port", if (u.port > 0) u.port else 443).put("users", JSONArray().put(user))
        return JSONObject()
            .put("tag", tag)
            .put("protocol", "vless")
            .put("settings", JSONObject().put("vnext", JSONArray().put(server)))
            .put("streamSettings", streamSettings(q, host))
    }

    private fun streamSettings(q: Map<String, String>, originalHost: String): JSONObject {
        val network = when (val t = (q["type"] ?: "tcp").lowercase()) { "splithttp" -> "xhttp"; "raw" -> "tcp"; else -> t }
        val security = (q["security"] ?: "none").lowercase()
        val hostHeader = q["host"]?.takeIf { it.isNotEmpty() }
        val path = q["path"]?.takeIf { it.isNotEmpty() } ?: "/"
        val s = JSONObject().put("network", network).put("security", security)

        when (network) {
            "tcp" -> if (q["headerType"] == "http") {
                s.put("tcpSettings", JSONObject().put("header", JSONObject().put("type", "http").put("request",
                    JSONObject().put("path", JSONArray().put(path))
                        .put("headers", JSONObject().put("Host", JSONArray().put(hostHeader ?: originalHost))))))
            }
            "ws" -> s.put("wsSettings", JSONObject().put("path", path).put("host", hostHeader ?: originalHost))
            "httpupgrade" -> s.put("httpupgradeSettings", JSONObject().put("path", path).put("host", hostHeader ?: originalHost))
            "grpc" -> s.put("grpcSettings", JSONObject().put("serviceName", q["serviceName"] ?: "").apply {
                q["authority"]?.takeIf { it.isNotEmpty() }?.let { put("authority", it) }
                if (q["mode"] == "multi") put("multiMode", true)
            })
            "xhttp" -> s.put("xhttpSettings", JSONObject().put("path", path).put("mode", q["mode"] ?: "auto")
                .put("host", hostHeader ?: originalHost).apply {
                    q["extra"]?.let { runCatching { put("extra", JSONObject(it)) } }
                })
            else -> throw IllegalArgumentException("Unsupported transport $network")
        }

        val sni = q["sni"]?.takeIf { it.isNotEmpty() } ?: hostHeader ?: originalHost
        val fp = q["fp"]?.takeIf { it.isNotEmpty() }
        when (security) {
            "tls" -> s.put("tlsSettings", JSONObject().put("serverName", sni).apply {
                fp?.let { put("fingerprint", it) }
                q["alpn"]?.takeIf { it.isNotEmpty() }?.let { put("alpn", JSONArray(it.split(","))) }
                if (q["allowInsecure"] == "1" || q["insecure"] == "1") put("allowInsecure", true)
            })
            "reality" -> {
                val pbk = q["pbk"]?.takeIf { it.isNotEmpty() } ?: error("reality link without pbk")
                s.put("realitySettings", JSONObject().put("serverName", sni).put("fingerprint", fp ?: "chrome").put("publicKey", pbk).apply {
                    q["sid"]?.let { put("shortId", it) }
                    q["spx"]?.let { put("spiderX", it) }
                    q["pqv"]?.takeIf { it.isNotEmpty() }?.let { put("mldsa65Verify", it) }
                })
            }
            "none" -> Unit
            else -> throw IllegalArgumentException("Unsupported security $security")
        }
        return s
    }

    private fun plainProxy(u: URI, scheme: String, tag: String): JSONObject {
        val host = u.host?.removeSurrounding("[", "]") ?: error("missing host")
        val socks = scheme.startsWith("socks")
        val port = if (u.port > 0) u.port else if (scheme == "https") 443 else if (socks) 1080 else 8080
        val server = JSONObject().put("address", host).put("port", port)
        u.rawUserInfo?.takeIf { it.isNotEmpty() }?.let {
            server.put("users", JSONArray().put(JSONObject().put("user", decode(it.substringBefore(':'))).put("pass", decode(it.substringAfter(':', "")))))
        }
        return JSONObject()
            .put("tag", tag)
            .put("protocol", if (socks) "socks" else "http")
            .put("settings", JSONObject().put("servers", JSONArray().put(server)))
            .apply {
                if (scheme == "https") put("streamSettings", JSONObject().put("security", "tls").put("tlsSettings", JSONObject().put("serverName", host)))
            }
    }

    private fun query(u: URI): Map<String, String> =
        u.rawQuery?.split("&")?.filter { it.isNotEmpty() }?.associate {
            decode(it.substringBefore("=")) to decode(it.substringAfter("=", ""))
        } ?: emptyMap()

    private fun decode(s: String): String = URLDecoder.decode(s.replace("+", "%2B"), "UTF-8")
}
