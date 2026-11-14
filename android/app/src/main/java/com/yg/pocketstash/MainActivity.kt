package com.yg.pocketstash

import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import coil.Coil
import coil.ImageLoader
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Headers
import okhttp3.OkHttpClient
import java.io.File

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val repo = DownloadRepo(applicationContext)

        // 缩略图 CDN 有防盗链: 所有图片请求带上站点 Referer
        val imgLoader = ImageLoader.Builder(applicationContext)
            .okHttpClient {
                // 每条请求可自带 Referer（站群图必须用详情页完整 URL）；这里只在缺失时兜底
                OkHttpClient.Builder().addInterceptor { chain ->
                    val orig = chain.request()
                    val b = orig.newBuilder().header("User-Agent", Http.UA)
                    if (orig.header("Referer") == null) b.header("Referer", "https://www.baidu.com/")
                    chain.proceed(b.build())
                }.build()
            }
            .build()
        Coil.setImageLoader(imgLoader)

        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) { App(repo) }
        }
    }
}

// MARK: 主框架 (抓取 / 片库 两个 Tab)

@Composable
fun App(repo: DownloadRepo) {
    var tab by remember { mutableIntStateOf(0) }
    var playing by remember { mutableStateOf<String?>(null) } // 本地路径或 http 流地址
    var playingRef by remember { mutableStateOf<String?>(null) } // 播放 Referer（站群 m3u8 必需）

    if (playing != null) {
        PlayerScreen(url = playing!!, referer = playingRef,
            onClose = { playing = null; playingRef = null })
        return
    }

    Scaffold(
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = tab == 0, onClick = { tab = 0 },
                    icon = { Text("⬇") }, label = { Text("抓取") })
                NavigationBarItem(
                    selected = tab == 1, onClick = { tab = 1 },
                    icon = { Text("▦") }, label = { Text("片库") })
            }
        }
    ) { pad ->
        Box(Modifier.padding(pad)) {
            when (tab) {
                0 -> FetchScreen(repo, onDownloaded = { tab = 1 },
                    onPlay = { u, r -> playing = u; playingRef = r })
                else -> LibraryScreen(repo, onPlay = { u, _ -> playing = u; playingRef = null })
            }
        }
    }
}

// MARK: 封面图 —— 站群 CDN 防盗链: Referer 必须是详情页完整 URL, 站点根都不行
@Composable
fun Cover(url: String?, referer: String?, modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    val req = remember(url, referer) {
        ImageRequest.Builder(ctx)
            .data(url)
            .apply {
                if (!referer.isNullOrBlank()) {
                    headers(
                        Headers.Builder()
                            .add("Referer", referer)
                            .add("User-Agent", Http.UA)
                            .build()
                    )
                }
            }
            .crossfade(true)
            .build()
    }
    AsyncImage(
        model = req,
        contentDescription = null,
        contentScale = ContentScale.Crop,
        modifier = modifier
    )
}

// MARK: 抓取页 (点条目 = 大图预览+在线播放/下载, 点 ⬇ = 直接下载)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FetchScreen(repo: DownloadRepo, onDownloaded: () -> Unit, onPlay: (String, String?) -> Unit) {
    val ctx = LocalContext.current
    val sites = remember { SiteCatalog.load(ctx) }
    var siteIdx by remember { mutableIntStateOf(0) }
    var page by remember { mutableIntStateOf(1) }
    var items by remember { mutableStateOf<List<VideoItem>>(emptyList()) }
    var progress by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    var msg by remember { mutableStateOf<String?>(null) }
    var preview by remember { mutableStateOf<VideoItem?>(null) }
    var query by remember { mutableStateOf("") }
    var scanning by remember { mutableStateOf(false) } // 域名扫描中
    val presetKeywords = remember {
        listOf("中文字幕", "黑丝", "丝袜", "cos", "护士", "教师", "学生", "人妻",
               "熟女", "自慰", "户外", "校园", "网红", "主播", "麻豆", "糖心",
               "果冻", "天美", "无码", "女同")
    }
    val scope = rememberCoroutineScope()

    // 全源搜索：逐个站点搜，跳过被拦/超时的，合并去重。
    // 单个源被 Cloudflare 拦住时不会拖垮整个搜索。
    suspend fun searchAll(q: String): List<VideoItem> = withContext(Dispatchers.IO) {
        val out = LinkedHashMap<String, VideoItem>()
        for (s in sites) {
            if (out.size >= 80) break
            runCatching { Scraper(s).search(q) }.getOrNull()?.forEach { out.putIfAbsent(it.id, it) }
        }
        out.values.toList()
    }

    // 开机自检：当前域名能用就不动，不能用就静默扫一圈已知线路池换掉。
    // 全程后台跑，不挡界面，也不弹提示——失败就让用户自己点「更新域名」。
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            if (!SmPool.isAlive()) {
                val hit = runCatching { SmPool.scan(SmPool.KNOWN_HOSTS) }.getOrDefault(emptyList())
                hit.firstOrNull()?.let { SmPool.currentHost = it }
            }
        }
        // 域名定下来之后重载一次首页，避免拿的是旧域名的残留数据
        runCatching { Scraper(sites[siteIdx]).list(1) }.onSuccess { items = it }
    }

    // 进入页面 / 切换分类时自动拉第一页，省一次手动点击
    LaunchedEffect(siteIdx) {
        page = 1
        items = emptyList()
        msg = null
        runCatching { Scraper(sites[siteIdx]).list(1) }
            .onSuccess { items = it }
            .onFailure { msg = it.message ?: "加载失败" }
    }

    val startDownload: (VideoItem) -> Unit = { item ->
        msg = null
        scope.launch {
            progress = progress + (item.id to 0.0)
            runCatching { repo.download(sites[siteIdx], item) { p ->
                progress = progress + (item.id to p)
            } }
                .onSuccess {
                    progress = progress - item.id
                    onDownloaded()
                }
                .onFailure {
                    progress = progress - item.id
                    msg = it.message ?: "下载失败"
                }
        }
    }

    val startStream: (VideoItem) -> Unit = { item ->
        msg = null
        scope.launch {
            runCatching { Scraper(sites[siteIdx]).resolveMedia(item.pageURL, item.mediaUrl) }
                .onSuccess { onPlay(it, item.pageURL) }
                .onFailure { msg = it.message ?: "解析失败" }
        }
    }

    Column(Modifier.fillMaxSize().padding(12.dp)) {
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(sites.size) { i ->
                FilterChip(
                    selected = siteIdx == i,
                    onClick = { siteIdx = i },
                    label = { Text(sites[i].name) }
                )
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.weight(1f),
                singleLine = true,
                placeholder = { Text("搜索关键词") }
            )
            Spacer(Modifier.width(8.dp))
            Button(onClick = {
                val q = query.trim()
                if (q.isNotEmpty()) {
                    msg = null
                    scope.launch {
                        runCatching { searchAll(q) }
                            .onSuccess { items = it; if (it.isEmpty()) msg = "没有搜到结果" }
                            .onFailure { msg = it.message ?: "搜索失败" }
                    }
                }
            }) { Text("搜索") }
        }
        LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items(presetKeywords.size) { i ->
                AssistChip(onClick = {
                    val kw = presetKeywords[i]
                    query = kw
                    msg = null
                    scope.launch {
                        runCatching { searchAll(kw) }
                            .onSuccess { items = it; if (it.isEmpty()) msg = "没有搜到结果" }
                            .onFailure { msg = it.message ?: "搜索失败" }
                    }
                }, label = { Text(presetKeywords[i]) })
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("第 $page 页")
            Spacer(Modifier.width(8.dp))
            OutlinedButton(onClick = { if (page > 1) page-- }) { Text("-") }
            Spacer(Modifier.width(4.dp))
            OutlinedButton(onClick = { page++ }) { Text("+") }
            Spacer(Modifier.width(8.dp))
            Button(onClick = {
                msg = null
                scope.launch {
                    runCatching { Scraper(sites[siteIdx]).list(page) }
                        .onSuccess { items = it }
                        .onFailure { msg = it.message ?: "加载失败" }
                }
            }) { Text("加载列表") }
            Spacer(Modifier.width(6.dp))
            OutlinedButton(onClick = {
                page = kotlin.random.Random.nextInt(1, 801)
                msg = null
                scope.launch {
                    runCatching { Scraper(sites[siteIdx]).list(page) }
                        .onSuccess { items = it }
                        .onFailure { msg = it.message ?: "加载失败" }
                }
            }) { Text("随机") }
            Spacer(Modifier.width(6.dp))
            OutlinedButton(
                enabled = !scanning,
                onClick = {
                    if (scanning) return@OutlinedButton
                    scanning = true
                    msg = "正在扫描 sm***.vip 域名…"
                    scope.launch {
                        val alive = runCatching { SmPool.scan() }.getOrDefault(emptyList())
                        scanning = false
                        if (alive.isEmpty()) {
                            msg = "没扫到可用域名，换个网络再试"
                        } else {
                            SmPool.currentHost = alive.first()
                            msg = "换到 ${alive.first()}（共 ${alive.size} 个可用）"
                            page = 1
                            runCatching { Scraper(sites[siteIdx]).list(1) }
                                .onSuccess { items = it }
                                .onFailure { msg = "已换域名，但列表加载失败：${it.message}" }
                        }
                    }
                }
            ) { Text(if (scanning) "扫描中…" else "更新域名") }
        }
        msg?.let { Text(it, color = MaterialTheme.colorScheme.error, maxLines = 2) }
        Spacer(Modifier.height(4.dp))

        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(items, key = { it.id }) { item ->
                Card(onClick = { preview = item }) {
                    Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Cover(
                            url = item.thumbURL,
                            referer = item.pageURL,
                            modifier = Modifier
                                .size(width = 110.dp, height = 62.dp)
                                .clip(RoundedCornerShape(6.dp))
                        )
                        Spacer(Modifier.width(8.dp))
                        Column(Modifier.weight(1f)) {
                            Text(item.title, style = MaterialTheme.typography.bodySmall,
                                 maxLines = 2)
                            if (progress.containsKey(item.id)) {
                                val p = progress[item.id] ?: 0.0
                                LinearProgressIndicator(
                                    progress = { p.toFloat() },
                                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp))
                                Text("${(p * 100).toInt()}%",
                                     style = MaterialTheme.typography.labelSmall)
                            }
                        }
                        IconButton(onClick = { startDownload(item) }) {
                            Text("⬇", style = MaterialTheme.typography.titleLarge)
                        }
                    }
                }
            }
        }
    }

    // 大图预览弹层: 在线播放 或 下载
    if (preview != null) {
        ModalBottomSheet(onDismissRequest = { preview = null }) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                Cover(
                    url = preview!!.thumbURL,
                    referer = preview!!.pageURL,
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(16f / 9f)
                        .clip(RoundedCornerShape(10.dp))
                )
                Spacer(Modifier.height(10.dp))
                Text(preview!!.title, style = MaterialTheme.typography.titleSmall)
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(
                        onClick = {
                            val picked = preview!!
                            preview = null
                            startStream(picked)
                        },
                        modifier = Modifier.weight(1f)
                    ) { Text("▶ 在线播放") }
                    OutlinedButton(
                        onClick = {
                            val picked = preview!!
                            preview = null
                            startDownload(picked)
                        },
                        modifier = Modifier.weight(1f)
                    ) { Text("⬇ 下载到本地") }
                }
                Spacer(Modifier.height(20.dp))
            }
        }
    }
}

// MARK: 片库页

@Composable
fun LibraryScreen(repo: DownloadRepo, onPlay: (String, String?) -> Unit) {
    var entries by remember { mutableStateOf(repo.loadLibrary()) }
    var bucket by remember { mutableStateOf("全部") }
    val buckets = remember(entries) {
        listOf("全部") + entries.map { it.bucket }.distinct().sorted()
    }
    val filtered = if (bucket == "全部") entries else entries.filter { it.bucket == bucket }

    LaunchedEffect(Unit) { entries = repo.loadLibrary() }

    Column(Modifier.fillMaxSize().padding(12.dp)) {
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(buckets.size) { i ->
                FilterChip(
                    selected = bucket == buckets[i],
                    onClick = { bucket = buckets[i] },
                    label = { Text(buckets[i]) }
                )
            }
        }
        Spacer(Modifier.height(8.dp))
        if (filtered.isEmpty()) {
            Text("还没有片子 — 去「抓取」页下载后自动入库")
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(filtered, key = { it.id }) { e ->
                Card(onClick = { onPlay(e.filePath, null) },
                     modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(10.dp)) {
                        Text(e.title, style = MaterialTheme.typography.bodyMedium,
                             maxLines = 1)
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            AssistChip(onClick = {}, label = { Text(e.bucket) })
                            AssistChip(onClick = {}, label = { Text(e.site) })
                        }
                    }
                }
            }
        }
    }
}

// MARK: 播放页 (本地文件 + http 流通吃, m3u8 流带 Referer)

@Composable
fun PlayerScreen(url: String, referer: String? = null, onClose: () -> Unit) {
    val ctx = LocalContext.current
    val player = remember(url) {
        // 加大缓冲：m3u8 分片拉取抖动时不容易卡住
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(30_000, 120_000, 2_000, 5_000)
            .build()
        val p = ExoPlayer.Builder(ctx).setLoadControl(loadControl).build()
        if (url.startsWith("http")) {
            val reqProps = buildMap {
                put("User-Agent", Http.UA)
                if (!referer.isNullOrBlank()) put("Referer", referer)
            }
            val httpFactory = DefaultHttpDataSource.Factory()
                .setDefaultRequestProperties(reqProps)
                .setAllowCrossProtocolRedirects(true)
                .setConnectTimeoutMs(15_000)
                .setReadTimeoutMs(30_000)
            val source = DefaultMediaSourceFactory(httpFactory)
                .createMediaSource(MediaItem.fromUri(Uri.parse(url)))
            p.setMediaSource(source)
        } else {
            p.setMediaItem(MediaItem.fromUri(Uri.fromFile(File(url))))
        }
        p.prepare()
        p.playWhenReady = true
        p
    }
    Box(Modifier.fillMaxSize()) {
        AndroidView(
            factory = { v -> PlayerView(v).apply { this.player = player } },
            modifier = Modifier.fillMaxSize()
        )
        TextButton(onClick = onClose, modifier = Modifier.padding(8.dp)) { Text("← 返回") }
    }
    DisposableEffect(Unit) { onDispose { player.release() } }
}
