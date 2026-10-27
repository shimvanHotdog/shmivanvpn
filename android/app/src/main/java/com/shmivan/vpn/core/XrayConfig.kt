package com.shmivan.vpn.core

import org.json.JSONArray
import org.json.JSONObject

/** Builds the Xray JSON config for Android: a TUN inbound fed by VpnService plus the same routing as macOS. */
object XrayConfig {
    const val SOCKS_PORT = 10808

    fun build(profile: Profile, split: SplitSettings): String {
        val sniffing = JSONObject().put("enabled", true).put("destOverride", arr("http", "tls", "quic")).put("routeOnly", true)
        val inbounds = JSONArray()
            .put(JSONObject().put("tag", "tun-in").put("protocol", "tun").put("port", 0)
                .put("settings", JSONObject().put("name", "xray0").put("MTU", 1500))
                .put("sniffing", sniffing))
            .put(JSONObject().put("tag", "socks-in").put("protocol", "socks").put("listen", "127.0.0.1").put("port", SOCKS_PORT)
                .put("settings", JSONObject().put("udp", true)).put("sniffing", sniffing))

        val outbounds = JSONArray()
            .put(UriParser.outbound(profile.uri, "proxy"))
            .put(JSONObject().put("tag", "direct").put("protocol", "freedom")
                .put("streamSettings", JSONObject().put("sockopt", JSONObject().put("domainStrategy", "UseIP"))))
            .put(JSONObject().put("tag", "block").put("protocol", "blackhole"))
            .put(JSONObject().put("tag", "dns-out").put("protocol", "dns"))

        return JSONObject()
            .put("log", JSONObject().put("loglevel", "warning"))
            .put("dns", JSONObject().put("tag", "dns-internal").put("servers", arr("1.1.1.1", "8.8.8.8")).put("queryStrategy", "UseIPv4"))
            .put("inbounds", inbounds)
            .put("outbounds", outbounds)
            .put("routing", JSONObject().put("domainStrategy", "IPIfNonMatch").put("rules", rules(split)))
            .toString(2)
    }

    private fun rules(split: SplitSettings): JSONArray {
        val rules = JSONArray()
        // DNS sent into the tunnel is answered by Xray's own resolver, which always goes through the proxy.
        rules.put(JSONObject().put("inboundTag", arr("tun-in")).put("port", "53").put("network", "udp").put("outboundTag", "dns-out"))
        rules.put(JSONObject().put("inboundTag", arr("dns-internal")).put("outboundTag", "proxy"))

        if (split.mode == SplitMode.OFF) {
            rules.put(JSONObject().put("network", "tcp,udp").put("outboundTag", "proxy"))
            return rules
        }
        if (split.blockAds) rules.put(JSONObject().put("domain", arr("geosite:category-ads-all")).put("outboundTag", "block"))
        if (split.bypassLan) {
            rules.put(JSONObject().put("ip", arr("geoip:private")).put("outboundTag", "direct"))
            rules.put(JSONObject().put("domain", arr("geosite:private")).put("outboundTag", "direct"))
        }
        val listed = if (split.mode == SplitMode.BYPASS_LISTED) "direct" else "proxy"
        val other = if (split.mode == SplitMode.BYPASS_LISTED) "proxy" else "direct"

        val domains = split.domains.mapNotNull(::normalizeDomain).toMutableList()
        val ips = split.ips.map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }.toMutableList()
        split.countries.map { it.trim().lowercase() }.filter { it.length == 2 && it.all(Char::isLetter) }.forEach {
            domains += "domain:$it"
            ips += "geoip:$it"
        }
        if (domains.isNotEmpty()) rules.put(JSONObject().put("domain", JSONArray(domains.distinct())).put("outboundTag", listed))
        if (ips.isNotEmpty()) rules.put(JSONObject().put("ip", JSONArray(ips.distinct())).put("outboundTag", listed))
        // With "only listed" + selected apps, the apps are already the only traffic in the tunnel: send it all through.
        val appOnly = split.mode == SplitMode.ONLY_LISTED && split.apps.isNotEmpty() && domains.isEmpty() && ips.isEmpty()
        rules.put(JSONObject().put("network", "tcp,udp").put("outboundTag", if (appOnly) "proxy" else other))
        return rules
    }

    fun normalizeDomain(raw: String): String? {
        var d = raw.trim()
        if (d.isEmpty() || d.startsWith("#")) return null
        if (listOf("geosite:", "domain:", "full:", "keyword:", "regexp:", "ext:").any { d.lowercase().startsWith(it) }) return d
        if (d.contains("://")) d = runCatching { java.net.URI(d).host }.getOrNull() ?: d
        while (d.startsWith("*.") || d.startsWith(".")) d = d.removePrefix("*.").removePrefix(".")
        return d.takeIf { it.isNotEmpty() }?.let { "domain:${it.lowercase()}" }
    }

    private fun arr(vararg v: String) = JSONArray(v.toList())
}
