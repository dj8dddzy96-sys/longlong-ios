package com.yg.pocketstash

object Classifier {
    // 标签 → 分类映射 (与 iPhone 版一致, 改这张表即可)
    private val map = listOf(
        "日系" to listOf("jav", "censored", "uncensored", "japan", "japanese"),
        "自拍" to listOf("amateur", "homemade", "selfie", "cam"),
        "欧美" to listOf("hd", "blonde", "brunette", "interracial", "milf"),
        "动图" to listOf("hentai", "anime", "animated", "cartoon"),
        "亚洲" to listOf("korean", "thai", "chinese", "asian"),
    )

    fun bucket(siteTags: List<String>): String {
        val lower = siteTags.map { it.lowercase() }
        for ((b, keys) in map) {
            if (lower.any { t -> keys.any { t.contains(it) } }) return b
        }
        return "未分类"
    }
}
