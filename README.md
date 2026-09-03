# arxiv-feed

个人用的 arXiv 每日论文流，全部跑在本机：点一下「更新」→ 抓当天新论文 → Codex 生成中文速览 + 细粒度标签 → 本地算主题向量；Mac 端像刷小红书一样刷卡片，点进去先看速览，需要时再点「生成深度解读」让 Codex 精读全文（结果缓存），行为信号反哺推荐排序。

## 结构

- `server/` — 本机后台（FastAPI，launchd 常驻在 127.0.0.1:8787）
  - `app/arxiv_fetch.py` — arXiv API 抓取（按分类，近 7 天；公告有延迟所以窗口不能小）
  - `app/llm.py` — 通过 ChatGPT.app 自带的 Codex CLI（`codex exec`）调用 gpt-5.6-sol：速览按批（low 推理，15 篇/次，JSON schema 约束输出）、深度解读单篇（xhigh 推理，读全文）
  - `app/embed.py` — 无依赖的哈希词袋向量（标题/标签/任务/方法加权），用于相似推荐
  - `app/recommend.py` — 兴趣画像（行为加权 + 时间衰减）+ 关注词条命中 + 新鲜度混合排序（+ 探索位）
  - `app/topics.py` — 关注词条：设置里维护的方向列表（存 prefs 表），每个方向由 Codex 补英文关键词；命中标题/标签记 1.0、命中摘要 0.85、否则用向量相似度
  - `app/pipeline.py` — 更新管道：抓取 → 速览 → 向量（可选预解读，默认关），后台线程跑并上报进度
  - `app/search.py` — 精搜：Codex 结合你的研究背景把方向翻成 intent + 4-8 个带限定词的英文短语（或用 `|` 直接给短语）→ arXiv API 按投稿日期窗口检索（每个短语「精确短语 OR 各词共现」，合并后 ≤500 篇候选）→ Codex 逐篇打相关分（0-3），只留明确相关的 → Semantic Scholar batch 拿引用数 → 按引用取前 80 → Codex 批量生成速览 + 从论文首页作者块读出机构（大厂/大组打分）
  - `app/main.py` — API：`/feed` `/saved` `/search` `/search/{id}` `/papers/{id}` `/papers/{id}/interpret` `/events` `/update` `/update/status` `/stats`
- `macapp/` — SwiftUI 客户端（无需 Xcode，`./build.sh` 出 `build/ArxivFeed.app`，图标由 `Icon/make_icon.swift` 生成）

## 安装 / 重启后台

```bash
server/deploy/install_local.sh
```

首次会建 venv、装依赖、从 `.env.example` 生成 `.env`，并注册 launchd 服务 `local.arxivfeed.api`（开机自启，日志在 `server/logs/api.log`）。改了 `.env`（模型、推理强度、分类、每次速览/解读数量）或代码后再跑一次即可重启。

前提：ChatGPT.app 已登录（Codex CLI 用 `~/.codex/auth.json` 的登录态）。

## 每日流程

app 顶栏「更新」（⌘U）→ 后台跑管道，顶栏显示进度（抓取 → 速览 N/M），完成后自动刷新 feed。深度解读只在详情页点「生成深度解读」时才生成（xhigh，几分钟一篇）。也可以命令行跑：`server/venv/bin/python server/run_pipeline.py`（加 `--interpret` 并设置 `PRE_INTERPRET>0` 才会顺带精读推荐位前几篇）。

## 关注词条

设置（⌘,）里的「发现页 · 关注词条」：加/删方向（中英文都行，默认视频生成 / 全双工语音 / 视频量化），保存后 Codex 给每个方向补一组英文关键词（`GET/PUT /prefs/topics`）。发现页排序 = 0.35 行为画像 + 0.35 词条命中 + 0.30 新鲜度（没有画像时 0.55 命中 + 0.45 新鲜度），命中的卡片封面带 ★ 词条名。

## 精搜

app 中间的「精搜」tab：输入方向（中文即可）+ 时间窗（3/6 个月，1/2/3 年）→ 十几秒出候选，约 1.5 分钟后 Codex 精筛 + 引用数到位自动重排，随后速览和机构陆续填上（全部完成约 3-4 分钟）；可切「按引用量 / 按大厂·大组」排序。结果上方会显示 Codex 对方向的理解和检索式，点铅笔可把检索式放回搜索框改（`|` 分隔，直接搜就跳过翻译）。设置里的「研究背景」是给 Codex 消歧用的（`.env` 的 `RESEARCH_CONTEXT` 只是首次默认值）。结果同样只有速览，点开后手动「生成深度解读」。Semantic Scholar 免 key 偶尔 429，会自动退避重试；`.env` 里填 `S2_API_KEY` 更稳。

## 行为信号

`POST /events`，kind 取值：`impression`（曝光）、`click`（点入）、`dwell`（停留秒数，value）、`like`/`unlike`、`dislike`、`save`/`unsave`。曝光过/点过/点踩/收藏过的不再出现在 feed；被撤销的 like/save 不计入画像。

## 打包给别人

```bash
./package.sh
```

生成 `dist/ArxivFeed-<版本>.dmg`（版本号在 `macapp/build.sh` 的 `VERSION`），标准的「拖进 Applications」安装盘。app 自带后台源码（`Contents/Resources/server`），对方第一次打开时自动装到 `~/Library/Application Support/ArxivFeed/server`：用本机 python3 建 venv、装依赖、注册 launchd 常驻（只监听 127.0.0.1）；以后升级 app 会自动同步后台代码。对方需要 macOS 14+、python3（命令行工具 / Homebrew / conda 任一，没有的话 app 里有按钮装命令行工具）、已登录的 ChatGPT 桌面版（速览用它的 Codex，模型名会从对方的 `~/.codex/config.toml` 读）。研究背景和关注词条在 app 设置里填。

没有 Developer ID 签名时，对方第一次打开会被 Gatekeeper 拦下：系统设置 → 隐私与安全性 → 拉到最下面「仍要打开」（DMG 背景图上写了）。有 Apple 开发者账号的话 `SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<notarytool profile> ./package.sh` 会签名、公证、staple，就没有这一步。

自己的开发机：launchd 指向代码仓库（`server/deploy/install_local.sh` 装的），app 检测到 plist 不是它自己写的就不会动它。
