package com.shmivan.vpn.core

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

data class Profile(val id: String = UUID.randomUUID().toString(), val name: String, val uri: String)

enum class SplitMode { OFF, BYPASS_LISTED, ONLY_LISTED }

data class SplitSettings(
    val mode: SplitMode = SplitMode.BYPASS_LISTED,
    val bypassLan: Boolean = true,
    val blockAds: Boolean = false,
    /** Two-letter country codes: "ru" -> geoip:ru + every *.ru domain. */
    val countries: List<String> = emptyList(),
    val domains: List<String> = emptyList(),
    val ips: List<String> = emptyList(),
    /** Package names, handled natively by VpnService allowed/disallowed apps. */
    val apps: List<String> = emptyList(),
)

data class AppState(
    val profiles: List<Profile> = emptyList(),
    val selectedId: String? = null,
    val split: SplitSettings = SplitSettings(),
) {
    val selected: Profile? get() = profiles.firstOrNull { it.id == selectedId } ?: profiles.firstOrNull()
}

/** Persists [AppState] as JSON in SharedPreferences. */
class Store private constructor(context: Context) {
    private val prefs = context.getSharedPreferences("state", Context.MODE_PRIVATE)
    private val _state = MutableStateFlow(load())
    val state: StateFlow<AppState> = _state

    fun update(transform: (AppState) -> AppState) {
        _state.update(transform)
        prefs.edit().putString("json", encode(_state.value)).apply()
    }

    /** Adds every supported link in [text]; returns how many were new. */
    fun importLinks(text: String): Int {
        var added = 0
        update { s ->
            val fresh = UriParser.links(text).filter { link -> s.profiles.none { it.uri == link } }
                .filter { runCatching { UriParser.outbound(it, "proxy") }.isSuccess }
                .map { Profile(name = UriParser.displayName(it), uri = it) }
            added = fresh.size
            s.copy(profiles = s.profiles + fresh, selectedId = s.selectedId ?: fresh.firstOrNull()?.id)
        }
        return added
    }

    private fun load(): AppState = runCatching { decode(JSONObject(prefs.getString("json", null)!!)) }.getOrDefault(AppState())

    private fun encode(s: AppState) = JSONObject().apply {
        put("profiles", JSONArray(s.profiles.map { JSONObject().put("id", it.id).put("name", it.name).put("uri", it.uri) }))
        put("selectedId", s.selectedId)
        put("split", JSONObject().apply {
            put("mode", s.split.mode.name)
            put("bypassLan", s.split.bypassLan)
            put("blockAds", s.split.blockAds)
            put("countries", JSONArray(s.split.countries))
            put("domains", JSONArray(s.split.domains))
            put("ips", JSONArray(s.split.ips))
            put("apps", JSONArray(s.split.apps))
        })
    }.toString()

    private fun decode(o: JSONObject): AppState {
        fun JSONArray?.strings() = this?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
        val profiles = o.optJSONArray("profiles")?.let { a ->
            (0 until a.length()).map { a.getJSONObject(it) }.map { Profile(it.getString("id"), it.getString("name"), it.getString("uri")) }
        } ?: emptyList()
        val sp = o.optJSONObject("split") ?: JSONObject()
        return AppState(
            profiles = profiles,
            selectedId = o.optString("selectedId").takeIf { it.isNotEmpty() && it != "null" },
            split = SplitSettings(
                mode = runCatching { SplitMode.valueOf(sp.optString("mode")) }.getOrDefault(SplitMode.BYPASS_LISTED),
                bypassLan = sp.optBoolean("bypassLan", true),
                blockAds = sp.optBoolean("blockAds", false),
                countries = sp.optJSONArray("countries").strings(),
                domains = sp.optJSONArray("domains").strings(),
                ips = sp.optJSONArray("ips").strings(),
                apps = sp.optJSONArray("apps").strings(),
            ),
        )
    }

    companion object {
        @Volatile private var instance: Store? = null
        fun get(context: Context) = instance ?: synchronized(this) {
            instance ?: Store(context.applicationContext).also { instance = it }
        }
    }
}
