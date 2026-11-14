package com.yg.pocketstash

import android.content.Context
import android.os.Environment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI

data class LibEntry(
    val id: String,
    val title: String,
    val site: String,
    val bucket: String,
    val filePath: String,
    val addedAt: Long
)

class DownloadRepo(ctx: Context) {

    private val base: File = ctx.getExternalFilesDir(null) ?: ctx.filesDir
    private val dir: File = File(base, Environment.DIRECTORY_MOVIES + "/Videos")
    private val indexFile: File = File(base, "library.json")

    fun loadLibrary(): MutableList<LibEntry> {
        val out = mutableListOf<LibEntry>()
        if (!indexFile.exists()) return out
        runCatching {
            val arr = JSONArray(indexFile.readText())
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                out += LibEntry(
                    o.getString("id"), o.getString("title"), o.getString("site"),
                    o.getString("bucket"), o.getString("filePath"), o.getLong("addedAt")
                )
            }
        }
        return out
    }

    private fun saveLibrary(list: List<LibEntry>) {
        val arr = JSONArray()
        list.forEach { e ->
            arr.put(JSONObject().apply {
                put("id", e.id); put("title", e.title); put("site", e.site)
                put("bucket", e.bucket); put("filePath", e.filePath); put("addedAt", e.addedAt)
            })
        }
        indexFile.writeText(arr.toString())
    }

    fun exists(id: String): Boolean = loadLibrary().any { it.id == id }

    suspend fun download(
        cfg: SiteConfig,
        item: VideoItem,
        onProgress: (Double) -> Unit
    ): LibEntry = withContext(Dispatchers.IO) {
        val media = Scraper(cfg).resolveMedia(item.pageURL, item.mediaUrl)
        dir.mkdirs()
        val isHls = media.substringBefore('?').endsWith(".m3u8")
        val ext = if (isHls) "ts" else media.substringBefore('?').substringAfterLast('.', "mp4")
        val safe = item.title.replace(Regex("[/\\\\?%*|\"<>:]"), "_").ifBlank { item.id }
        val out = File(dir, "${item.id}_$safe.$ext")

        if (isHls) {
            hlsDownload(media, item.pageURL, out, onProgress)
        } else {
            directDownload(media, item.pageURL, out, onProgress)
        }

        val entry = LibEntry(
            id = item.id, title = item.title, site = item.site,
            bucket = Classifier.bucket(item.tags),
            filePath = out.absolutePath, addedAt = System.currentTimeMillis()
        )
        synchronized(this) {
            val lib = loadLibrary()
            lib.removeAll { it.id == entry.id }
            lib.add(entry)
            saveLibrary(lib)
        }
        entry
    }

    private fun newReq(url: String, referer: String): Request =
        Request.Builder().url(url)
            .header("User-Agent", Http.UA)
            .header("Referer", referer)
            .build()

    private fun directDownload(media: String, referer: String, out: File, onProgress: (Double) -> Unit) {
        Http.client.newCall(newReq(media, referer)).execute().use { r ->
            check(r.isSuccessful) { "HTTP ${r.code}" }
            val body = r.body ?: throw IllegalStateException("空响应")
            val total = body.contentLength()
            var done = 0L
            body.byteStream().use { ins ->
                out.outputStream().use { outs ->
                    val buf = ByteArray(256 * 1024)
                    while (true) {
                        val n = ins.read(buf)
                        if (n < 0) break
                        outs.write(buf, 0, n)
                        done += n
                        if (total > 0) onProgress(done.toDouble() / total)
                    }
                }
            }
        }
    }

    /** HLS (m3u8) → 顺序下载分片合成单个 .ts 文件 */
    private fun hlsDownload(media: String, referer: String, out: File, onProgress: (Double) -> Unit) {
        fun fetchText(u: String): String =
            Http.client.newCall(newReq(u, referer)).execute().use { r ->
                check(r.isSuccessful) { "HTTP ${r.code}" }
                r.body?.string() ?: throw IllegalStateException("空响应")
            }

        var playlist = fetchText(media)
        // 主播放列表 → 取第一个子列表
        if (playlist.contains("#EXT-X-STREAM-INF")) {
            val child = playlist.lines()
                .firstOrNull { it.isNotBlank() && !it.startsWith("#") }
                ?: throw IllegalStateException("播放列表解析失败")
            playlist = fetchText(URI(media).resolve(child.trim()).toString())
        }
        check(!Regex("#EXT-X-KEY:METHOD=(?!NONE)").containsMatchIn(playlist)) {
            "该视频为加密流, 请使用「在线播放」"
        }
        val baseUri = URI(media)
        val segs = playlist.lines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { baseUri.resolve(it.trim()).toString() }
        check(segs.isNotEmpty()) { "没有视频分片" }

        var done = 0
        out.outputStream().use { outs ->
            for (s in segs) {
                Http.client.newCall(newReq(s, referer)).execute().use { r ->
                    check(r.isSuccessful) { "分片下载失败 HTTP ${r.code}" }
                    val body = r.body ?: throw IllegalStateException("空分片")
                    body.byteStream().copyTo(outs, 256 * 1024)
                }
                done++
                onProgress(done.toDouble() / segs.size)
            }
        }
    }
}
