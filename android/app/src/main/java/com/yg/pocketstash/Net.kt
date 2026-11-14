package com.yg.pocketstash

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

// MARK: 站点配置 (assets/sites.json)
// type = "html" → 网页采集：listURL 里的 {page} 占位 + itemSelector 选条目
// type = "cms"  → 苹果CMS v10 JSON 接口：apiBase + cateId，直出 m3u8/mp4

data class SiteConfig(
    val name: String,
    val listURL: String,           // {page} 占位 (html)
    val firstPageURL: String?,     // 第 1 页专用 URL (可选)
    val itemSelector: String,
    val titleSelector: String?,
    val tagSelector: String?,
    val thumbSelector: String?,
    val titleDecode: Boolean,      // 标题 XOR-128 解码
    val videoUrlTemplate: String?, // 详情页视频直链模板, {vid} 占位
    val vidPattern: String?,       // 从详情页 HTML 提取 {vid} 的正则
    val searchURL: String?,        // 搜索接口模板, {q} 占位
    val headers: Map<String, String>,
    val type: String = "html",
    val apiBase: String? = null,   // cms: https://host
    val cateId: String? = null,    // cms: 分类 type_id
    val keyword: String? = null,   // cms: 关键词题材（有则用 wd= 搜索代替 t= 分类）
    val subRandom: Boolean = false // true: URL 里的 {sub} 换成 6 位随机串（反封锁站群）
)

/** 随机子域字符集（站群用 6 位小写字母+数字） */
private const val SUB_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789"

object SiteCatalog {
    fun load(ctx: Context): List<SiteConfig> {
        val raw = ctx.assets.open("sites.json").bufferedReader().use { it.readText() }
        val arr = JSONArray(raw)
        return (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            val headers = mutableMapOf<String, String>()
            o.optJSONObject("headers")?.let { h ->
                h.keys().forEach { k -> headers[k] = h.optString(k) }
            }
            fun opt(key: String): String? =
                o.optString(key).takeUnless { it.isEmpty() || it == "null" }
            SiteConfig(
                name = o.getString("name"),
                listURL = o.optString("listURL", ""),
                firstPageURL = opt("firstPageURL"),
                itemSelector = o.optString("itemSelector", "a"),
                titleSelector = opt("titleSelector"),
                tagSelector = opt("tagSelector"),
                thumbSelector = opt("thumbSelector"),
                titleDecode = o.optBoolean("titleDecode", false),
                videoUrlTemplate = opt("videoUrlTemplate"),
                vidPattern = opt("vidPattern"),
                searchURL = opt("searchURL"),
                headers = headers,
                type = opt("type") ?: "html",
                apiBase = opt("apiBase"),
                cateId = opt("cateId"),
                keyword = opt("keyword"),
                subRandom = o.optBoolean("subRandom", false)
            )
        }
    }
}

// MARK: HTTP（带 5 分钟内存缓存，翻页回来不用重发请求）

object Http {
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private const val TTL = 5 * 60 * 1000L

    private val cache = object : LinkedHashMap<String, Pair<Long, String>>(64, 0.75f, true) {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, Pair<Long, String>>) =
            size > 120
    }

    private fun cacheGet(k: String): String? = synchronized(cache) {
        val v = cache[k] ?: return null
        if (System.currentTimeMillis() - v.first > TTL) { cache.remove(k); null } else v.second
    }

    private fun cachePut(k: String, v: String) = synchronized(cache) {
        cache[k] = System.currentTimeMillis() to v
    }

    const val UA: String =
        "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"

    fun html(url: String, headers: Map<String, String> = emptyMap(), useCache: Boolean = true): String {
        val key = url + "|" + headers.entries.joinToString("&") { "${it.key}=${it.value}" }
        if (useCache) cacheGet(key)?.let { return it }
        val b = Request.Builder().url(url)
            .header("User-Agent", UA)
            .header("Accept", "text/html,application/xhtml+xml,application/json")
        headers.forEach { (k, v) -> b.header(k, v) }
        val body = client.newCall(b.build()).execute().use { r ->
            r.body?.string() ?: ""
        }
        if (useCache && body.isNotEmpty()) cachePut(key, body)
        return body
    }

    /**
     * POST 表单提交 —— 神秘站 (/so.html?wd=xxx) 这类搜索只认 POST。
     * 注意：结果不缓存（搜索词组合太多，塞满 LRU 反而把列表页挤掉）。
     */
    fun form(
        url: String,
        params: Map<String, String>,
        headers: Map<String, String> = emptyMap()
    ): String {
        val fb = FormBody.Builder()
        params.forEach { (k, v) -> fb.add(k, v) }
        val b = Request.Builder().url(url)
            .header("User-Agent", UA)
            .header("Accept", "text/html,application/xhtml+xml")
            .header("Referer", url)
            .post(fb.build())
        headers.forEach { (k, v) -> b.header(k, v) }
        return client.newCall(b.build()).execute().use { r -> r.body?.string() ?: "" }
    }
}

// MARK: 抓取

data class VideoItem(
    val id: String,
    val site: String,
    val pageURL: String,
    val title: String,
    val tags: List<String>,
    val thumbURL: String?,
    val mediaUrl: String? = null   // cms 直出直链；html 站点为 null，需进详情页解析
)

class Scraper(private val cfg: SiteConfig) {

    private val isCms: Boolean get() = cfg.type == "cms" && cfg.apiBase != null

    // 站群反封锁：每次实例化时随机生成 6 位子域，如 https://qw8b4p.sm230.vip/
    private val sub: String =
        if (cfg.subRandom) (1..6).map { SUB_CHARS.random() }.joinToString("") else ""

    /** 把 {sub} 占位换成当前随机子域，{host} 换成当前生效域名 */
    private fun u(s: String): String {
        var r = s
        if (cfg.subRandom) r = r.replace("{sub}", sub).replace("{host}", SmPool.currentHost)
        return r
    }

    // 站点标题混淆: 每个字符 XOR 128
    private fun xor128(s: String): String =
        String(s.map { (it.code xor 128).toChar() }.toCharArray())

    private fun pageTitle(a: Element): String {
        var title = a.attr("title")
        if (title.isBlank()) cfg.titleSelector?.let {
            a.selectFirst(it)?.let { el -> title = el.attr("alt").ifBlank { el.text() } }
        }
        if (title.isBlank()) title = a.text()
        if (cfg.titleDecode) {
            for (sc in a.select("script")) {
                val m = Regex("""l\('(.+?)'\)""").find(sc.data())
                if (m != null) {
                    val dec = xor128(m.groupValues[1]).trim()
                    if (dec.isNotBlank()) { title = dec; break }
                }
            }
        }
        return title.trim()
    }

    private fun parseItems(html: String, base: String): List<VideoItem> {
        val doc = Jsoup.parse(html, base)
        return doc.select(cfg.itemSelector).mapNotNull { a ->
            val href = a.absUrl("href")
            if (href.isEmpty()) return@mapNotNull null
            var title = pageTitle(a)
            if (title.isBlank()) title = href.substringAfterLast('/')
            var thumb: String? = null
            cfg.thumbSelector?.let {
                a.selectFirst(it)?.let { img ->
                    thumb = img.absUrl("data-src").ifEmpty { img.absUrl("src") }.ifEmpty { null }
                }
            }
            val tags = cfg.tagSelector?.let { a.select(it).map { t -> t.text() } } ?: emptyList()
            VideoItem(md5(href), cfg.name, href, title, tags, thumb)
        }
    }

    // MARK: 苹果CMS v10 JSON 解析
    // vod_play_url 形如 "中字$https://x/a/index.m3u8#第2集$https://x/b/index.m3u8"

    private fun pickMedia(playUrl: String): String? {
        if (playUrl.isBlank()) return null
        val first = playUrl.substringBefore('#')
        val cand = first.substringAfterLast('$').trim()
        if (cand.startsWith("http")) return cand
        return Regex("""https?://[^\s"'$]+?\.(?:m3u8|mp4|mkv|webm)""").find(playUrl)?.value
    }

    private fun parseCms(raw: String): List<VideoItem> {
        val root = runCatching { JSONObject(raw) }.getOrNull() ?: return emptyList()
        val arr = root.optJSONArray("list") ?: return emptyList()
        val out = ArrayList<VideoItem>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val vid = o.optString("vod_id")
            if (vid.isBlank()) continue
            val media = pickMedia(o.optString("vod_play_url")) ?: continue
            val name = o.optString("vod_name").ifBlank { "无标题" }
            val pic = o.optString("vod_pic").takeUnless { it.isBlank() || it == "null" }
            val tags = buildList {
                o.optString("type_name").takeUnless { it.isBlank() }?.let { add(it) }
                o.optString("vod_remarks").takeUnless { it.isBlank() }?.let { add(it) }
            }
            out += VideoItem(
                id = md5("${cfg.apiBase}#$vid"),
                site = cfg.name,
                pageURL = vid,
                title = name,
                tags = tags,
                thumbURL = pic,
                mediaUrl = media
            )
        }
        return out
    }

    private fun cmsList(page: Int): List<VideoItem> {
        val base = cfg.apiBase ?: return emptyList()
        val kw = cfg.keyword?.takeUnless { it.isBlank() }
        val t = if (kw != null) {
            "&wd=" + java.net.URLEncoder.encode(kw, "UTF-8")
        } else {
            cfg.cateId?.takeUnless { it.isBlank() }?.let { "&t=$it" } ?: ""
        }
        val url = "$base/api.php/provide/vod/?ac=videolist&pg=$page$t"
        return parseCms(Http.html(url, cfg.headers))
    }

    suspend fun list(page: Int): List<VideoItem> = withContext(Dispatchers.IO) {
        if (isCms) return@withContext cmsList(page)
        val url = u(if (page == 1 && cfg.firstPageURL != null) cfg.firstPageURL
                  else cfg.listURL.replace("{page}", page.toString()))
        val html = Http.html(url, cfg.headers)
        parseItems(html, url)
    }

    /** 全库关键词搜索 */
    suspend fun search(query: String): List<VideoItem> = withContext(Dispatchers.IO) {
        val q = java.net.URLEncoder.encode(query, "UTF-8")
        if (isCms) {
            val base = cfg.apiBase!!
            val t = cfg.cateId?.takeUnless { it.isBlank() }?.let { "&t=$it" } ?: ""
            return@withContext parseCms(Http.html("$base/api.php/provide/vod/?ac=videolist&wd=$q&pg=1$t", cfg.headers))
        }
        val tmpl = cfg.searchURL ?: throw IllegalStateException("该站点不支持搜索")
        val url = u(tmpl.replace("{q}", q))
        // 神秘站 /so.html 只接受 POST 表单，GET 会返回空列表
        if (cfg.subRandom || url.endsWith("/so.html")) {
            return@withContext parseItems(Http.form(url, mapOf("wd" to query), cfg.headers), url)
        }
        parseItems(Http.html(url, cfg.headers), url)
    }

    suspend fun resolveMedia(pageURL: String, mediaUrl: String? = null): String =
        withContext(Dispatchers.IO) {
            // CMS 站点在列表阶段已经拿到直链，零额外请求
            if (!mediaUrl.isNullOrBlank()) return@withContext mediaUrl
            if (isCms) {
                val base = cfg.apiBase!!
                val raw = Http.html("$base/api.php/provide/vod/?ac=detail&ids=$pageURL", cfg.headers)
                parseCms(raw).firstOrNull()?.mediaUrl?.let { return@withContext it }
                throw IllegalStateException("未解析到直链")
            }
            // html 站点：带上站点 headers 再请求详情页（原来漏了，导致 403）
            val html = Http.html(pageURL, cfg.headers)
            if (cfg.videoUrlTemplate != null) {
                val p = Regex(cfg.vidPattern ?: """data-id="(\d+)"""")
                p.find(html)?.groupValues?.get(1)?.let { vid ->
                    return@withContext cfg.videoUrlTemplate!!.replace("{vid}", vid)
                }
            }
            val doc = Jsoup.parse(html, pageURL)
            for (prop in listOf("og:video:url", "og:video:secure_url", "og:video")) {
                doc.selectFirst("meta[property=$prop]")?.attr("content")?.let { c ->
                    if (c.substringAfterLast('.', "").isNotEmpty()) return@withContext c
                }
            }
            doc.selectFirst("video source")?.attr("abs:src")?.takeIf { it.isNotEmpty() }
                ?.let { return@withContext it }
            for (re in listOf(
                Regex("(https?:[^\"']+?\\.mp4)[^\"]*?"),
                Regex("(https?:[^\"']+?\\.m3u8)[^\"]*?"),
                Regex("(https?:[^\"']+?\\.mkv)[^\"]*?"),
                Regex("(https?:[^\"']+?\\.webm)[^\"]*?")
            )) {
                re.find(html)?.groupValues?.get(1)?.let { return@withContext it }
            }
            throw IllegalStateException("未解析到直链")
        }

    private fun md5(s: String): String =
        MessageDigest.getInstance("MD5").digest(s.toByteArray())
            .joinToString("") { "%02x".format(it) }
}

// MARK: sm 站群域名池 — 手动「更新域名」用
// 规则：前缀 sm + 3 位随机数字 + .vip，访问时前置 6 位随机子域
// 活站特征：页面里含 XOR-128 编码的「神秘电影」= 秩祘疵忱

object SmPool {

    private const val MARK = "\u79e3\u7958\u75be\u5ff1" // 神秘电影 的 XOR-128 形式

    /** 当前生效域名，UI 的「更新域名」按钮会改写它 */
    @Volatile
    var currentHost: String = "sm230.vip"

    /** 已知线路池（从站点自己的 vip.js 里挖出来的，缺 234） */
    val KNOWN_HOSTS: List<String> = listOf(
        "sm230.vip", "sm231.vip", "sm232.vip", "sm233.vip", "sm235.vip",
        "sm236.vip", "sm237.vip", "sm238.vip", "sm239.vip", "sm240.vip",
        "sm241.vip", "sm242.vip", "sm243.vip", "sm244.vip", "sm245.vip",
        "sm246.vip", "sm247.vip", "sm248.vip"
    )

    /** 开机自检用：当前域名还活着吗 */
    fun isAlive(host: String = currentHost): Boolean = probe(host)

    /** 生成 n 个互不相同的候选域名，如 sm230.vip */
    fun randomCandidates(n: Int = 30): List<String> =
        generateSequence { "sm%03d.vip".format((0..999).random()) }
            .distinct().take(n).toList()

    /** 测单个域名：最多试 2 个随机子域，命中站点特征即算活 */
    private fun probe(host: String): Boolean {
        repeat(2) {
            val sub = (1..6).map { SUB_CHARS.random() }.joinToString("")
            val body = runCatching {
                Http.html("https://$sub.$host/", useCache = false)
            }.getOrNull() ?: return@repeat
            if (body.contains(MARK) || body.contains("vodbox")) return true
        }
        return false
    }

    /** 并发扫描候选域名，返回活着的 host 列表 */
    suspend fun scan(candidates: List<String> = randomCandidates()): List<String> =
        withContext(Dispatchers.IO) {
            val pool = java.util.concurrent.Executors.newFixedThreadPool(8)
            try {
                candidates.map { h -> pool.submit(java.util.concurrent.Callable { h to probe(h) }) }
                    .mapNotNull { f -> runCatching { f.get() }.getOrNull() }
                    .filter { it.second }
                    .map { it.first }
            } finally {
                pool.shutdown()
            }
        }
}
