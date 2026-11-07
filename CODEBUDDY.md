# CODEBUDDY.md — Luma mod 源码工程

> 本目录是 **Luma Framework 的 fork**，含自建的「四海兄弟：最终版」（Mafia: Definitive Edition）mod。
> 笔记与决策库在同机的 Obsidian vault：`D:\AiWorkSpace\Obsidian Vault\Game\`

---

## 编译

```bash
# 站内脚本（封装了 VS2022 环境与项目路径）
build-mafiade.bat        # 只编译 Mafia: DE 的 mod
build.bat                # 全部
```

**产物**：`Binaries\x64-Development-Release\Luma-Mafia Definitive Edition.addon`

**⛔ 编译前必须清空 `http_proxy` / `https_proxy`（含大写）** —— 否则 MSBuild 报 `MSB6001`。

## 部署

```bash
# 1) 确认游戏没在跑（运行中的进程会锁住 DLL）
tasklist | grep -i mafia
# 2) 拷 addon 到游戏目录
cp -f "Binaries/x64-Development-Release/Luma-Mafia Definitive Edition.addon" \
      "/f/SteamLibrary/steamapps/common/Mafia Definitive Edition/"
```

**注意**：`.hlsl` 着色器**不打包进 addon**，是运行时从
`<游戏目录>/Luma/Mafia Definitive Edition/` 加载的 ⇒ 改 hlsl 后要**单独同步**那个文件。

游戏目录当前结构（可用的分层）：

| 文件 | 身份 |
| --- | --- |
| `dxgi.dll` | OptiScaler（26,513,920） |
| `d3d11.dll` | Luma 的 ReShade（5,590,528） |
| `Luma-Mafia Definitive Edition.addon` | 本工程产物 |

## 工程结构要点

| 路径 | 说明 |
| --- | --- |
| `Source/Games/Mafia Definitive Edition/main.cpp` | **本 mod 全部逻辑**（~1240 行，含大量注释说明每处改动的原因） |
| `Source/Core/core.hpp` | Luma 框架核心（**尽量不改**，改前先确认是否有官方开关） |
| `Source/Core/includes/resource_upgrades.hpp` | 交换链/纹理升级的枚举与选项 |
| `Shaders/Mafia Definitive Edition/` | 本游戏的自定义着色器（RCAS 锐化） |
| `Shaders/Includes/` | 可复用头（`RCAS.hlsl` / `FXAA.hlsl` / `Tonemap.hlsl` / `ColorGradingLUT.hlsl` 等） |
| `Source/Games/Mafia III/main.cpp` | ⭐ **最重要的参考资料** —— 同引擎的官方 mod，多数做法照抄它 |

## main.cpp 的关键点（改之前先读这段）

**核心宏**：
```cpp
#define CHECK_GRAPHICS_API_COMPATIBILITY 1   // ⛔ 必需：否则 OptiScaler 的 D3D12 设备会让 Luma 断言崩溃
```

**已定位的 pass**：

| hash | 身份 |
| --- | --- |
| `0x37B05605` / `0x7B9B914F` | **真正的时间重投影**（3 纹理 = 颜色 / 历史帧 / UV 空间 MV，Karis 3×3 方差钳制）—— 我们替换的就是它 |
| `0x2B974E48` | ⛔ **红鲱鱼**：是**单通道 R32** 上的 FXAA，不是主色 AA（曾误当目标，导致噪点） |
| `0x121A4A96` | 位置缓冲填充（从中捕获深度，因为 AA pass 无 DSV） |
| `0x916B1D65` | Tonemap（与 RenoDX 同 hash） |
| `0x747C6210` | Tonemap **之后**的邻域方差锐化 ⛔ 不要整体取消 |
| `0x5C8BCE6A` | bloom 亮部提取（5-tap 均值 + `max(·,0)`） |
| `0xA75736C5` | PreTAA copy ⛔ 一帧出现多次 |

**抖动位置**：TAA pass 的 **PS 常量缓冲 slot 0 的 `float32`/`float33`**
（值域 `[-0.5, 0.5]`，量化值 1/8、1/6、5/18… ⇒ 8 相位 Halton；同 cbuffer 的 float28/29 是 NDC 版本）

## ⛔ 改代码的铁律

1. **不要取消游戏的 pass —— 改参数，别跳过 draw**
   - `0x747C6210` 在 `if (cb0[0].z > 0)` **之外**还有 `mul r0, r0, v1`（逐像素乘算）⇒ 整体取消会黑屏
   - 要关它的锐化应改 `cb0[0].z`，而不是 `return Replaced`
2. **用脚本插入代码后必须 `grep -n` 核对作用域与声明顺序**
   （局部变量声明必须在首次使用前；常量放文件作用域，别塞进 struct）
3. **取注入的着色器用 `.find()`，不能用 `operator[]`** —— 后者会默认插入，破坏并发读
4. **`DrawCustomPixelShader` 不恢复状态** ⇒ 必须用 `DrawStateStack<DrawStateStackType::FullGraphics>` 包住
5. **新增自定义着色器**三步：`native_shaders_definitions.emplace(...)` 声明 → `.find()` 取回 → `DrawCustomPixelShader(...)` 绘制
6. 每个有风险的改动**都在源码里写了原因注释** —— 改之前先读注释，别重踩
7. **从某个 pass 里"顺手抓"资源时必须校验** ⛔
   - `0x121A4A96`（位置缓冲填充）的 PS 是 `mov o0.xyzw, v0.xyzw`（6 指令、零资源）⇒ **引擎也拿它做 depth-only 的阴影绘制**
   - 我们原来抓"最后一次绑定的 DSV"，于是间歇性抓到 **`2048x2048 R16_TYPELESS arr=2`（阴影级联）** 当主深度 —— `dlss5-bridge.log` 里 `game depth is R16_TYPELESS (53)` ↔ `R24G8_TYPELESS (44)` 一秒之内来回跳
   - **探针日志只打一次**（每变体一次）恰好是对的 ⇒ 一个采样点不足以证明"输入正确"。**多帧/多个来源交叉验证**
   - 修复：`IsUsableMainDepth()` 校验（单 slice + ≥ 渲染分辨率×0.9），**被拒绝的候选不覆盖上一个有效值**

## ⛔ 改文档/笔记的铁律 + 安全改文工装

**教训（2026-10-04）**：改 Obsidian 笔记 `游戏插件组合库.md` 时用「整文件重写」，把 419 行的文件写成
**15 段旋转拼接的 6297 行**（一级标题重复 165 次）；靠「文件内部还残留一份完整 419 行副本」+ 逐项复核才还原。

**四条纪律**
1. **只用定点替换**改写现有文件（IDE 的替换工具，或 `text-guard.ps1 replace`）—— **永不整文件重写**；写前确认 Obsidian 没开着该笔记。
2. **改前 snapshot、改后 verify**（加 `-RestoreOnFail` 失败自动回滚）。脚本类文件每次编辑后**重新补 UTF-8 BOM**（PS 5.1 按 GBK 读中文会炸）。
3. **PowerShell 替换用字面 `.Replace()`，不用 `-replace` 正则** —— `'$1' + '4. …'` 会拼成 `$14`，被当成第 14 组引用 ⇒ **静默**插入垃圾；
   正则若必须用：作用域**限定到目标小节**、缩进**显式写死**。
4. **修坏文件时先找「仍然完整的那一份副本」**，校验锚点行号（如"某章节在文件第 N 行"）再重建 —— 比凭记忆重写可靠得多。

**工装**：`Scripts\tools\text-guard.ps1`（五个动作，全部自测通过）

| 动作 | 用途 |
| --- | --- |
| `snapshot <文件>` | 改前留基线：备份 + 结构指纹（行数 / SHA256 / 各级标题清单 / `$数字` 计数） |
| `verify <文件> [-RestoreOnFail]` | 改后体检：UTF-8 合法性、同一行或同一标题重复 ≥12 次（旋转拼接硬指纹）、行数暴涨、新增 `$数字`、一级标题整段消失 |
| `replace <文件> -Old -New [-Expect n]` | **字面**替换（非正则）+ 自动 snapshot + 复验 + 失败自动回滚；`-Expect` 校验命中数 |
| `restore <文件>` | 回滚到最近快照（回滚前状态另存 `pre-restore-*`） |
| `scan <目录>` | 扫目录找已被改坏的 `.md`/`.txt`；误报基线已实测校准（表格行不计、分章同名标题 2~11 次只提示） |

状态目录 `logs\text-guard\`（保留最近 10 代）。实测留档：`游戏插件组合库.md` 基线 **431 行 / 12 个标题**；
全 vault **282 个 `.md`/`.txt` 体检 0 损坏**（7 个"分章同名"仅提示）。

## 方法论 SOP：多组件冲突诊断（2026-10-04 ② 战役固化）

适用：HDR / 超分 / 帧生成 / 注入器 这类「多个第三方组件同时注入」的兼容问题。
**一句话**：先用**单变量隔离**把冲突锁到某两个组件之间，再按**成本递增**试逃生开关；每一步都留证据（日志 + WER 故障模块 + 状态快照），**崩了也是数据**。

| # | 动作 | 怎么做 |
| --- | --- | --- |
| 1 | 布置组合 | `Scripts\diag\combo.ps1 <状态>`（五组件开关 luma/renodx/opti/nr-bridge/renodx-nr；自动写状态快照；游戏在跑则拒绝执行） |
| 2 | 实机跑一轮 | 30~60 秒进场景；开 overlay 确认各面板在、功能生效 |
| 3 | 采证 | `Scripts\diag\collect.ps1 -Label <名>` → 日志 + 崩溃签名 + WER 模块清单 + 控制台摘要 |
| 4 | 读因果链 | 日志里找**最后一条成功**与**第一条失败**（如 `XeFG Log: Backbuffer format is not valid. Found 40.`），WER 给故障模块 |
| 5 | 二分下一个变量 | 只改一个开关 → 回第 1 步 |

**硬规则**
- ⛔ **一次只改一个变量**；新增组件先并进 `combo.ps1` 的开关表再测。
- ⛔ **别信「必崩」的经验**：② 里"Luma×RenoDX 必崩"是错的，真凶是第三方（XeFG 只认 8-bit 或 HDR10）的格式约束 ⇒ 结论必须能被日志逐行对上。
- **旁路证伪也要写进文档**：`OptiScaler.ini [HDR] ForceHDR/UseHDR10` 无效（FG 交换链格式继承自游戏交换链），避免下次重试。
- **逃生开关按成本排序**：overlay 现切 → 改 ini → 重编自己 → fork 上游；每条记「位置 + 需要什么」。
- 实机只能由用户跑 ⇒ 必须给**明确的观察清单**（看哪几个信号、怎么算好），而不是"跑一下"。
- **工具本身要自测**：新脚本先拿"已知坏样本"验一遍（本工具即用 `rotated.md` / `$14` / 标题消失三例校准），否则误报会让人不再看它。

## 当前状态

| 项 | 状态 |
| --- | --- |
| TAA → DLAA 替换 | ✅ 接管率 99.9%，四样输入（颜色/深度/MV/输出）已验证 |
| RCAS 锐化（里程碑 4） | ⚠️ 默认改 **0（关闭）** —— 2026-10-04 查明"锐度不足"的真因是 `MVJittered` 误置，修好后底图已够锐，再锐化只把噪点带回来 |
| OptiFG-XeFG 4 倍 + NR | ✅ 跑通 |
| 噪点 | ❌ DLAA 固有取舍（已穷尽排除，见 `Luma 移植实战手册.md`） |
| HDR | ✅ **已打通**（2026-10-04）：fork RenoDX 改走 HDR10（21 行）⇒ Luma(DLAA) + RenoDX(HDR10) + OptiScaler(XeFG 4x + NR) 同开跑通，见 ② |
| 代码清理（review 8 项） | ✅ 2026-10-04 完成，见下 |
| 实机部署 | DEV 版（清理后）已部署 `F:\...\Mafia Definitive Edition\`，日志逐项对上基线：`draw_ok=true / colour=0 motion=2 / mv=slot 2 / jitter=0.125,0.2778 / RCAS 0.35 / hook:SR=7620:3810`｜回退用 `.addon.prev-cleanup` |

## 待办（可直接执行）

### ① 代码清理 —— ✅ 已完成（2026-10-04）

`Source/Games/Mafia Definitive Edition/main.cpp`，1346 行，`Development-Release` 与 `Publishing-Release` **两个配置都编译通过**。

| # | 项 | 实际改动 |
| --- | --- | --- |
| 1 | 文件头重写 | 改为「release 1.0」：列出 pass 身份表（含 ⛔ 不可取消的三个）、已定案事实（无独立 MV / 抖动位置与写法 / reversed-Z / 噪点属固有取舍）、HDR 未做的原因；删掉「MV 未找到、jitter 未知、纹理升级已开」等 5 处反事实 |
| 2 | `forced_shader_names` | `2B974E48`→"FXAA on single-channel R32 (NOT the colour AA)"；两个 TAA→"TAA resolve A/B ← replaced by DLSS"；新增 `A75736C5`/`5C8BCE6A`/`747C6210` 三条带 `*` 的禁止取消标注 |
| 3 | 崩溃源 | **物理删除** `mv_probe_requested` / `mv_probe_done` / `mv_staging`，并留注释说明"CPU 读回崩过，不再有任何代码路径做读回" |
| 4 | 死代码 | 删除 `trace_left`、`logged_aa`、`has_drawn_tonemap`、`cb_dump_left`、`aa_dumps`、`skip_post_taa_composite`/`logged_composite_skip`、`mv_origin`、冗余的 `OnInit` 重复赋值 |
| 5 | 诊断隔离 | `kPreTaaRing` / `s_pre_taa_ring` / `mv_sniffed*` / `dlss_hook_mode` / `skip_game_sharpen` / `jitter_flip` 等全部进 `#if DEVELOPMENT` ⇒ **Publishing 版本里连代码都不存在** |
| 6 | 计数逻辑 | `aa_seen`/`aa_this_frame` 收拢为一处递增；删死赋值 `matched_index = ? 2 : 3` 与不可达的 `2B974E48` 分支（改名为 `resolve_name`/`resolve_index`）；日志的 MV 字段直接打印最终选用来源（`resolve input slot N = 3840x2160 R16G16B16A16_FLOAT`） |
| 7 | bloom pass | `0x5C8BCE6A` 的"取消"代码整段删除（它是 bloom 亮部提取），`shader_hashes_PostTaaComposite` 一并删掉 |
| 8 | ImGui 面板 | 正式版只留 3 项：SR 开关 / RCAS 强度（±0.05）/ MV 符号；其余 15 项进 `#if DEVELOPMENT` 的 "Dev switches" 段 |

**顺带定下的默认值**：`aa_auto_slots` 由 0（手动）改为 **1（按格式自动识别 + 安全门）** —— 这是它自己注释里写的 "recommended"，且实测游戏内 auto 得到的正是 `colour=0 / motion=2`，与手动值一致，而菜单场景会安全地回退到游戏原生 AA。

**⚠️ 别把这一条当成"没做完"**：工程有 `Development-Release`（定义 `DEVELOPMENT=1`）和 `Publishing-Release`（不定义）两套配置。**DEV 构建的 overlay 必然显示我们自己的 "Dev switches" 段，外加核心的 `Test Settings`（`core.hpp:14878`）和 `Developer Settings`（`core.hpp:14898`）**。要让面板真的只剩 3 项，只能部署 `Binaries\x64-Publishing-Release\…addon`（858KB，已验证含 SR/DLSS 代码、不含 `Dev switches` 字符串）。
**2026-10-04 的决定：开发未结束，保持 DEV 版部署，暂不切 Publishing**（切过去会失去 shader dump / pass 名字 / dev 参数开关，做 ② 时又得切回）。

### ③ 深度捕获 bug —— ✅ 已修复（2026-10-04，待实机复测）

**发现**：调 NR 时用 `dlss5-bridge.log` 的每帧参数快照才发现 —— 送给 DLSS/NR 的 `Depth` 在
`3840x2160 R24G8_TYPELESS arr=1`（正确）与 `2048x2048 R16_TYPELESS arr=2`（阴影级联，错误）之间来回跳。
探针日志只打印一次且恰好是对的，所以从没暴露。

**修复**（`main.cpp`）：
| # | 改动 | 作用 |
| --- | --- | --- |
| 1 | 新增 `IsUsableMainDepth()`：单 slice、`SampleDesc.Count==1`、尺寸 ≥ 渲染分辨率×0.9 | 从源头排除阴影级联数组 |
| 2 | 被拒绝的候选**不覆盖**上一个有效深度 + 节流日志（`[depth] accepted/rejected …`） | 宁可用上一帧的真深度 |
| 3 | 喂 SR 前若 `main_depth` 为空则本帧不接管（回退游戏原生 AA） | 不再送 null/错资源给 DLSS |

**实机复测结果（2026-10-04 11:27~11:30）**：修复确实生效 —— 探针 `[depth] main depth accepted: 3840x2160 R24G8_TYPELESS`、随后 3 次 `[depth] rejected: 512x512 R16_TYPELESS`（阴影图，被挡下）；bridge 侧 `game depth is R24G8_TYPELESS (44)` **7/7 恒定**（修前是来回跳）。
⛔ **但观感"没什么变化" ⇒ "深度是 NR 弱的主因"这个判断是错的**。这是一个"该修、但不影响观感"的 bug。

**于是主因回到契约/载波位置**，且找到了真正的开关（从 `renodx-dlss5.addon64` 自身的说明字符串挖出）：
- **`Hook point`（神经渲染区 / `NRHookPoint`）**：当前 `path=after`（管线内、DLAA 之后、Tonemap 之前）；addon 原文 —— *"At the Present hook point it works on the **finished picture**"* ⇒ **切到 `Present` 就是 Magpie 同一条路**
- *"Depth and motion for the Present hook point. Optional: the game's DLSS depth and motion will be used"* ⇒ **present 模式正好需要上面刚修好的深度/MV**（所以那次修复不是白做，只是当前路径下用不到）
- `Fixes` 区：`Brightness source` → `v1 (frame meter)`（`NRFeedMode=1`，对应我们契约里的 `exposure=ambiguous`）；`Motion scale X/Y`（`NRMVecScaleX/Y`）—— 原文：*"Near zero they see a still scene on every moving frame"* ⇒ 配错会让 NR 把移动画面当静止、**把改动 hold 住**
- `Look` 区：`Stabilize` 有 Motion/Static 之分，Motion 且无 MV 时会退化 ⇒ 建议先 `Static`
- present 模式可能被挡（addon 自带这些错误文案）：`present_format`（交换链色彩空间/格式）、`present_repeat`/`present_prefg`（帧生成）、`present_no_guides`、`present_busy`

### ④ ✅ 已证实：本作的"分层时间重投影"就是"人脸/手无变化"的元凶（2026-10-04）

**现象**：NR（RenoDX-DLSS5，`path=after`）在人脸/手上完全无变化，但同款 addon 在**别的游戏里非 present 模式**人脸也有变化 ⇒ **差异在本作游戏侧**。

**已证实（实测）**：本作一帧**两次**时间重投影（`resolve hooked 7620x, SR drawn 3810x` 精确 2:1），
**第二次覆盖角色/皮肤/半透明层**；`Second resolve in a frame: allowed → CANCELLED` 后
**脸/手立刻出现 DLAA/NR 特征**。Mafia III 官方 mod 的同源注释：`// This happens 3 times, for different parts of the image`。

**已落地**：`cancel_second_taa` 默认改为 **true**（DEV 面板仍可 A/B），并加一次性诊断
`[resolve #N in frame X] <name> writes <RTV0>`（告诉我们那层写的是哪个目标）。
⚠️ 待观察：那一层的 TAA history 不再推进 ⇒ 留意**玻璃/烟雾/水/头发**有无拖影或破面。

### ⑤ "Luma 漏了信息" —— 精确清单（bridge 每帧参数 dump）

| 输入 | 状态 | 影响 | 可否修 |
| --- | --- | --- | --- |
| Color / Output / Depth / MotionVectors | ✅ 全给（深度今天刚修好校验） | — | — |
| **ExposureTexture** | ❌ `not set by the game`，但标志里却声明 `AutoExposure`，且 `Pre.Exposure`/`Exposure.Scale` 恒 1.0 | NR 契约里直接是 **`exposure=ambiguous`** ⇒ 模型不知道输入多亮，改动幅度只能保守 ⇒ **最可疑的"弱"来源** | ✅ **可修**：① 面板 `Auto exposure: OFF`（免重编）② addon `Fixes → Brightness source = v1 (frame meter)` ③ 正解＝从 tonemap `0x916B1D65` 取曝光喂进 `draw_data.pre_exposure`（**Luma 上游也缺**：Mafia III 官方 mod 里就留着 `// TODO: find exposure? It's t4 of the tonemap shader...`） |
| TransparencyMask | ❌ `not set by the game` | 与"独立角色/透明层"直接相关 | 待评估 |
| NormalRoughness / DiffuseAlbedo / SpecularAlbedo / SpecularHitDistance | ❌ `UnsupportedParameter`（**D3D11 的 DLSS-SR 特性根本没有这几个键**） | RR 专用 guide；**DX12 原生 RR 的游戏能给，D3D11 游戏给不了** ⇒ 可能是"别的游戏 NR 明显更好"的**结构性**原因 | ❌ 除非换 DX12/RR 路径 |
| `MVLowRes` 标志 | Luma **无条件置位**（`DLSS.cpp:88` 注释：*"Always needed unless MVs are in output resolution"*） | DLAA 下 render==output，MV 本就是输出分辨率 ⇒ 这位严格说该清 | ⏸ 未验证（小项；`MVJittered` 那条已由反汇编定案，见 ⑦） |

### ⑥ ⛔ 已被 ⑦ 推翻：曾以为"输入域不匹配"（Stray 同为 R11G11B10 线性 HDR，证明不成立，保留供追溯）

**修正上一版表述**：关键**不是 present 模式**（用户观察正确：别的游戏非 present 人脸也有变化），
而是**模型看到的画面是不是"色调映射之后的最终画面"**。

| | 别的游戏（用户实测有效的那些） | 本作（Luma） |
| --- | --- | --- |
| 超分/DLSS 在哪 | **tonemap 之后**（LDR sRGB 画面） | **tonemap 之前**（`R11G11B10_FLOAT` + `IsHDR` + `encoding=linear`） |
| NR 挂 "after the upscaler" 拿到的 | ≈ **最终画面**（模型训练域） | **线性 HDR 中间产物**（不是训练域） |
| 结果 | 模型的判断直接落在画面上 | 只能以**相对倍率**回写（`units=relative`/`transfer=ratio`），再被本作 tonemap `0x916B1D65` + tonemap 后锐化 `0x747C6210` **重新映射** |

⇒ **中间调（皮肤/脸/手）落在 tonemap 曲线压得最狠的区间，改动被压掉最多** —— 精确解释"整体有一点、脸手几乎没有"。
附加恶化项：`exposure=ambiguous`（模型不知道输入绝对亮度）、`governor=stable+cuts` + `attack_release=4/0.5`（时域限制器倾向 hold）。

**决定性判定实验（不改代码，在 addon overlay 里做，按性价比）**：

| 序 | 操作 | 若画面**响应** | 若**毫无响应** |
| --- | --- | --- | --- |
| 1 | `Look` 区 `Strength` / `Detail` 拉到最大（`Stack passes` 也试 +1） | ✅ 只是本作需要更高强度 ⇒ 调参即可 | ❌ 判定为**域不匹配**：Luma 侧怎么补输入都没用 |
| 2 | `Neural Rendering` 区 `Hook point` → 试 **`Present`**（现在的理由更硬：本作超分在 tonemap 前，所以 `after upscaler` ≠ 最终画面） | ✅ 证实域不匹配、且 present 是唯一出路 | ❌ 与链路无关，回到强度/参数问题 |
| 3 | addon 的对比截图（F5） | 用它对"变化量"做客观判断，别靠肉眼 | 同左 |

**判据优先级**：先做 1。**若拉满都没反应 ⇒ 不要再花力气补输入（曝光/透明遮罩/RR guide），直接走 present 或接受上限。**

### ⑦ ⭐⭐ Stray vs Mafia DE 契约对照（用户提供的"对照组"，2026-10-04）

Stray 用 **Luma 官方 `Unreal Engine` 通用 mod**（`Luma-Unreal Engine.addon`，源码就在本仓库 `Source/Games/Unreal Engine/`），
同样的 NR addon 在那边**效果正常**（与 Magpie 差异不大）。对照 `dlss5-bridge.log` 的每帧参数快照：

| 字段 | Stray（正常） | Mafia DE（弱） | 结论 |
| --- | --- | --- | --- |
| Color | `3840x2160 R11G11B10_FLOAT` | `3840x2160 R11G11B10_FLOAT` | **一样** ⇒ "色调映射前/后"的域假设**不成立** |
| Width/OutWidth | `3840 / 3840`（无放大） | `3840 / 3840` | 一样 |
| ExposureTexture / TransparencyMask | `not set` / `not set` | `not set` / `not set` | 一样（所以"缺输入"不是差异） |
| Pre.Exposure / Exposure.Scale | `1.0 / 1.0` | `1.0 / 1.0` | 一样 |
| Depth | `R32G8X24_TYPELESS` | `R24G8_TYPELESS` | 等价（都是 reversed-Z） |
| MotionVectors | `R32G32_FLOAT`，`MV.Scale = 1.0` | `R16G16B16A16_FLOAT`，`MV.Scale = 3840,2160` | 各自编码一致（我们 UV 空间需换算） |
| **Create Flags** | **`75` = AutoExposure\|DepthInverted\|MVLowRes\|IsHDR** | **`79` = 上面再加 `MVJittered`** | ⭐ **唯一实质差异** |
| NR 契约 | `hdr=1 encoding=linear units=relative transfer=ratio` | 同 | 一样 |
| addon 自报警告 | **无** | **`motion_jittered`（唯一一条）** | ⭐ 与上面的标志位**一一对应** |
| DLSS Output 缓冲 | `R16G16B16A16_FLOAT` | `R11G11B10_FLOAT`（6 位尾数） | 第二嫌疑：NR 的差值载体精度低 16× |

**⇒ 主嫌疑：我们多置了 `MVJittered` 标志（`sr_mvs_jittered = 1`）。** addon 明说它的 NR 运行时**没有对应开关**，
所以 NR 的重投影精度会略低 ⇒ 配合 `governor=stable+cuts` 倾向"hold"，改动就进不了画面。
Stray 不置这一位、addon 不报警、效果正常 —— 三者互相印证。

**⛔ 结论被反汇编推翻（2026-10-04 当天纠正）**：`MVs jittered` **必须保持 ON**。

反汇编证据（`luma-mafiade\asm\0x37B05605.ps_5_0.cso.asm`，TAA resolve 本体）：
```
sample_indexable(texture2d) r0.xyzw, v1.xyxx, t2.xyzw, s0   // r0.xy = 运动矢量
add r1.xyzw, r0.xyxy, v1.xyxy                                // prevUV = curUV + MV，没有别的项
```
且该着色器**从未读取 `cb0[8]`**（正是我们读走并喂给 DLSS 的抖动 float32/33）——**全篇没有任何抖动修正项**。
⇒ 游戏自己的 TAA 之所以精确（SR 关闭时画面几乎无噪点），只能是因为**抖动已经烘在 MV 里**
⇒ 这个引擎就是"MV 含抖动"（与 Mafia III 同族引擎、Luma 官方 mod 取值一致）。

**为什么我会误判**：把 OFF 后的"看起来更锐"当成了"重投影修正了"。实际机制是
**DLSS 把抖动 delta 又加了一遍 ⇒ 历史帧对不齐 ⇒ 历史被部分丢弃**（少平均 = 更锐 + **噪点/亮点更多**）。
实测佐证：OFF 时**地面闪烁噪点与高对比边缘亮点变多**，切回 ON 两者**减少**。

**教训（两条，比结论本身更重要）**：
1. **"更锐"不等于"更对"** —— 时域累积被破坏同样会表现为"变锐"。要用**引擎自身着色器**这种硬证据定案，别用观感。
2. addon 的那条 `motion_jittered` 警告是**良性的**（它自己写 `tone=info actor=game`、"无需做任何更改"）——
   因为它不支持这个标志，并不代表标志设错了。**别为了让工具闭嘴去改正确的东西。**

**待复测（这次的连带影响）**：
1. **运动场景**（快速转镜头/移动物体）有无拖影或双影 —— 这是改这一位唯一的风险方向
2. **噪点**：底图变锐后，"噪点"的观感会变（旧结论"DLAA 固有取舍"需要重新评估）
3. ~~RCAS 强度回调~~ → ✅ **已定案：默认改为 `0`（= 整个 RCAS pass 跳过）**。理由：底图已够锐，再锐化只是把 DLAA 本来就被诟病的噪点带回来；面板保留 ±/归零按钮，需要时手动开

**次嫌疑（未验证）**：DLSS 输出缓冲精度 `R11G11B10` → FP16（＝重新打开纹理格式升级，**历史上出过银黑色块**，需重启才生效）。

❗**但它没有解决 NR 强度问题**（实测：警告消失后 NR 强度**几乎无变化**）⇒ 这一条修正的价值在
"**锐度 + 警告消失**"，NR 弱**另有原因**（见 ⑧）。教训：一条假设被证实时，要分开记录它**证明了什么**和
**没能证明什么**。

### ⑫ ✅ 结案（2026-10-04 晚，用户实测结论）

> **"认真对比后：只开一层 NR 时，除了 Magpie experimental 更亮、风格不同之外，与 ReShade 的 NR 已经没有很大区别。"**

⇒ "本作 NR 明显弱于 Magpie"**不是一个 Luma 缺陷**，而是：
1. **Magpie 在最终 LDR 画面上作业**（模型训练域），且它的输出直接上屏 ⇒ 风格更"亮/浓"；它在 HDR 前段跑的 ReShade/NR 必然显得淡
2. 加上今天修掉的两个真 bug（分层 resolve、深度抓错）后，本作这一侧也补齐了

**今天真正的产出（4 个真问题）**：
| # | 问题 | 状态 |
| --- | --- | --- |
| 1 | 代码清理（review 8 项） | ✅ 完成，两配置编译 |
| 2 | 深度捕获间歇抓成阴影级联（2048²/512² R16） | ✅ 修复（校验 + 不覆盖有效值） |
| 3 | 第二次时间重投影让**脸/手绕过 DLAA/NR** | ✅ 默认取消（`cancel_second_taa = true`） |
| 4 | RCAS 过度锐化（底图本就够锐） | ✅ 默认改 0 |

**被证伪的假设（3 条，均有硬判据，勿重试）**：
| 假设 | 判据 |
| --- | --- |
| "MVJittered 设错 ⇒ NR 弱" | 反汇编（`prevUV = curUV + MV`，无抖动项）+ A/B：只影响噪点/锐度，强度不变 |
| "输入域不对（tonemap 前 vs 后）" | Stray/FFXV 同为 `encoding=linear` |
| "输出缓冲要 FP16 / 缺曝光等输入" | FFXV 同样 `R11G11B10`、同样无曝光纹理，NR 正常 |

### ⑧ ⭐ NR 强度排查过程（已由 ⑫ 结案，保留供追溯）

已排除的：① 输入域（Stray 同为 R11G11B10 线性 HDR）② 缺输入（曝光/透明遮罩两边都没有）
③ `MVJittered`（实测与强度无关）④ 深度错误（修复后强度无变化）。

**剩余差异（Stray 正常 vs 本作弱）**：只有 **DLSS 输出缓冲精度** `R16G16B16A16_FLOAT` vs `R11G11B10_FLOAT`（6 位尾数）。

**下一步必须做"控制实验"**（在 addon overlay 的 `Look` 区）：把 `Strength` / `Detail` **拉满**、`Stack passes` +1，
看画面是否响应：
- **响应** ⇒ 只是本作需要更高强度，调参即可结束
- **毫无响应** ⇒ 模型的判断**进不了画面**，那就只剩 `Hook point: Present`（最终画面）或放弃

**量化指标不可用**：bridge 的 `brightness out/in after evaluate` 本作 0.85~0.88、Stray 0.83~0.93 ⇒ 无差异，
不能用来定位（记录以免重复尝试）。

### ⑨ ✅ 已定性：DLSS 模式下的"亮点/噪点闪烁"

观察（2026-10-04）：本作 DLSS 模式下，地面有闪烁噪点（NONE 模式几乎没有），高对比边缘有亮点。
**同位置 A/B 结果**：

| 切换 | 结果 | 结论 |
| --- | --- | --- |
| `Second resolve: CANCELLED → allowed` | 亮点/噪点**无变化** | 与"取消第二层 resolve"**无关** |
| `MVs jittered: OFF → ON` | 亮点/噪点**减少** | 属"时域累积"差异：**OFF 时历史被部分丢弃**（更锐但更闪） |

⇒ **定性：这是 DLAA 的时域累积本就少于游戏 TAA 的固有表现**（游戏的随机/dither 噪声被 TAA 糊掉、被 DLAA 保留），
而 `MVJittered=OFF` 会**放大**它。正确取值（ON）下它回到历史水平 —— 与手册里"噪点＝DLAA 固有取舍"一致。

### ⑪ ⭐⭐ 三方对照（Mafia DE / Stray / FFXV）—— 两个"正常"对照组把范围收窄到 2 个 bit

三个游戏都用 **Luma + dlss5-bridge + DLSS5 NR**。逐字段对比（`dlss5-bridge.log` 每帧参数 dump + `frame contract`）：

| 字段 | Mafia DE（弱） | Stray（正常） | **FFXV（正常）** |
| --- | --- | --- | --- |
| Color | `R11G11B10` | `R11G11B10` | `R11G11B10` |
| **Output** | `R11G11B10` | `R16G16B16A16_FLOAT` | **`R11G11B10`** |
| Depth / MV | R24G8 / R16G16B16A16F | R32G8X24 / R32G32F | R32G8X24 / R32G32F |
| ExposureTexture / TransparencyMask | 都没有 | 都没有 | 都没有 |
| Width / OutWidth | 3840/3840 | 3840/3840 | 3840/3840 |
| Pre.Exposure / Exposure.Scale | 1.0 / 1.0 | 1.0 / 1.0 | 1.0 / 1.0 |
| Jitter | 真值（像素空间） | 真值 | 真值（同样是 `uvJitter×分辨率`） |
| **Create Flags** | **`0x4F`**（+AutoExp+DepthInverted+MVJittered+MVLowRes+IsHDR） | `0x4B`（无 MVJittered） | **`0x43`（无 MVJittered、无 DepthInverted）** |
| **NR 契约** | `path=inline hdr=1 encoding=linear units=relative transfer=ratio guard=0 governor=stable+cuts exposure=ambiguous feed=v1` | 同 | **逐字段相同** |
| addon 自报警告 | `motion_jittered` ×1 | 无 | **无** |

**Luma 官方 FFXV mod 的取值**（`Source/Games/Final Fantasy XV/main.cpp:784-787`）：
```cpp
settings_data.hdr = true;  settings_data.auto_exposure = true;
settings_data.inverted_depth = false;   // ← 官方自己：false
settings_data.mvs_jittered   = false;   // ← 官方自己：false
```
（顺带旁证：它的抖动提取也是 `g_uvJitterOffset × g_screenSize` = 像素空间，与我们的读法一致）

**两个结论**：
1. ⛔ **"DLSS 输出缓冲 FP16 才够"这条假设被 FFXV 推翻** —— FFXV 输出同样是 `R11G11B10`，NR 正常
   ⇒ **纹理格式升级对本作 NR 强度没有价值**（⑩ 只保留"若要做 HDR 才需要"的意义）。
2. ✅ **范围收窄到 2 个 bit**：`DepthInverted` 与 `MVJittered`。其中 `MVJittered` 已实测（ON 更干净、
   切 OFF 噪点/亮点变多）⇒ 本作引擎语义确实含抖动，**保持 ON**。**剩下的唯一未验证项是 `DepthInverted`。**

⚠️ **关键提醒**：手册里 "Inverted depth" 曾被标"已排除"，**但那次是在深度输入还被间歇性抓错（阴影级联）的时候做的**
⇒ 那个结论已失效，必须**在深度修好之后重测**（DEV 面板 `Inverted depth (reversed-Z): ON/OFF` 实时可切）。

**2026-10-04 复测结果**：`Inverted depth` 切 OFF 后**肉眼几乎无差别**（`MVJittered` 也是"强度无变化，只影响噪点/锐度"）。
⇒ **两个 bit 都排除，"Luma 漏了信息"这条假设可以结案**：三方契约逐字段一致、两个 flag 都无可见差异。
⇒ 剩下的漏斗只收口到两处：
1. **addon 自身的强度/外观设置**在本作没配好 → 做 ⑧ 的**控制实验**（`Strength`/`Detail` 拉满、`Stack passes` +1），
   看画面是否响应。这是**唯一还没试过的杠杆**。
2. **我们的参照点可能错位** → 做**跨游戏对照**：在 FFXV（同 addon、同设置、同样 `encoding=linear` 契约）里 F6 开关 NR，
   对比差异幅度与 Mafia DE。若 FFXV 的差异也这么小 ⇒ 本作并不异常，是我们对"NR 该有多强"的期望有偏差。

**DepthInverted 的收尾（可选，硬判据）**：视觉无差别 ⇒ 值本身不影响观感，但"设错"会在遮挡/消隐边缘留下隐患。
可用 10 行 DEV 探针打印 position-fill pass 的 `DepthFunc`（`GREATER(_EQUAL)` = reversed-Z，`LESS(_EQUAL)` = 普通 Z）一次定案。

**✅ 已定案（2026-10-04 13:43，探针输出）**：
```
[depth] main pass depth state: DepthFunc=7 (GREATER_EQUAL), DepthEnable=yes, WriteAll=yes
        => reversed-Z = yes => sr_inverted_depth must be 1 (ON)
```
⇒ 本作确实是 **reversed-Z**（远平面 0），`sr_inverted_depth = 1` **正确**，**无需改代码**。
⚠️ 这也说明"reversed-Z"这条原本来自 Mafia III mod 的**假设**，现在变成了**实测事实**（注释里已记）。

**⭐ 由此三方对照完全闭合**：我们与两个"正常"对照组差异的那 2 个 bit，
**两个都是本作引擎的真实语义**，不是我们设错 ——

| bit | 本作 | FFXV / Stray | 定案依据 |
| --- | --- | --- | --- |
| `DepthInverted` | **ON** | OFF | 探针实测 `DepthFunc=GREATER_EQUAL` = reversed-Z |
| `MVJittered` | **ON** | OFF | 反汇编 `prevUV = curUV + MV`（无抖动项）+ A/B（ON 更干净） |
⇒ "Luma 漏了信息/设错了标志"这条路线**彻底结案**（⑫）。

### ⑩ ⭐ 纹理格式升级（Texture Format Upgrades）分析与分级实验

**一、机制**：资源**创建时**换格式。`GetBestResourceUpgradeFormat()` 对**所有非深度**格式一律返回
`r16g16b16a16_float`（深度按 stencil 给 `r32_g8_typeless`/`r32_typeless`），原内容会被转换复制过去。
命中条件 = `格式 ∈ texture_upgrade_formats` **且** 通过 `2d_size_filters`（LUT 特例可叠加）。

**二、我们的配置**（全部继承模板，见 `_Template/main.cpp:175-206`）
```cpp
swapchain_format_upgrade_type = None;   // ⛔ 我们关（开启后独占全屏切换死锁）
texture_format_upgrades_type  = None;   // ⛔ 我们关（车漆/地面"银黑色块"）
texture_upgrade_formats = { r8g8b8a8_unorm(+srgb,+typeless), b8g8r8a8_unorm(+srgb,+typeless),
                            r10g10b10a2_unorm(+typeless), r11g11b10_float };
texture_format_upgrades_lut_size = 32;  _lut_dimensions = _2D;   // ← 模板原样，未针对本作验证
2d_size_filters = SwapchainResolution | SwapchainAspectRatio | No1Px;
enable_samplers_upgrade = false;
```

**三、⚠️ 归因可能被混淆**："银黑色块"出现在**两个升级都开着**的版本；之后关纹理升级（花屏）+ 关交换链升级
（死锁）是**两次独立决策**。交换链 `scRGB` 改变的是**最终显示的色彩空间/显示合成**，其 bug 同样表现为
大面积高光爆"银"、暗部压"黑" ⇒ **必须分开重测**。

**四、三个嫌疑（按代码证据排序）**

| # | 嫌疑 | 依据 | 危险度 |
| --- | --- | --- | --- |
| 1 | **LUT 启发式抓错纹理**：`32/_2D` 匹配的是"任意 `1024x32`、单 mip、单层"且在格式列表里的纹理；上游默认 `lut_size = -1`（= 关闭） | `resource_upgrades.inl:297-318`；我们照抄模板值，**从未验证本作真实 LUT 的尺寸/维度** | 高（静默改掉一个我们看不懂的查找表 ⇒ 采样它的表面出块） |
| 2 | `SwapchainAspectRatio` 让**任意 16:9 尺寸**的纹理都可升级（`size_filter \|= aspect_ratio_filter`，与尺寸无关） | `resource_upgrades.inl:208-216` | 中（升级面远大于"全分辨率"） |
| 3 | 所有非深度格式**一律升成 FP16**，丢失 `_srgb` 变体 ⇒ 若游戏在"升级/未升级"两条路径间混写混读，颜色会差一次 sRGB 编解码 | `GetBestResourceUpgradeFormat()` 直接返回 `r16g16b16a16_float` | 中 |

**五、对我们到底有没有价值？**
- DLSS/NR 的**输入** Color：本作 `R11G11B10` 与 Stray **完全一样** ⇒ 不是差异
- **唯一差异**是 DLSS **输出缓冲**：Stray `R16G16B16A16_FLOAT`，本作 `R11G11B10`（6 位尾数）
⇒ 若这条有意义，**只需要把 HDR 色彩缓冲升到 FP16**，不需要全套升级。

**六、分级实验（成本递增，一次只动一层）**

| 阶段 | 配置 | 若画面正常 | 若再现花屏 |
| --- | --- | --- | --- |
| A | 只加 `r11g11b10_float`；filters 收窄为 `SwapchainResolution \| No1Px`；**LUT 关闭**（`lut_size=-1`） | ✅ 拿到 FP16 HDR 缓冲 ⇒ 再评 NR 是否变好 | ⇒ 说明问题在"HDR 缓冲升级本身"（阶段 B 无解，直接放弃） |
| B | 在 A 之上恢复 `SwapchainAspectRatio` | ✅ 说明花屏来自阶段 A 之外 | ⇒ 归因给"升级面过宽" |
| C | 在 B 之上恢复 LUT（`32/_2D`） | ✅ 说明 LUT 没问题 | ⇒ **确认嫌疑 #1**，即模板的 LUT 值不适合本作 |

**风险/代价**：升级要重建纹理（内存↑、启动变慢）、格式不匹配的拷贝要走 Luma 的重定向 shader（多一层）、
**改完要重启游戏才生效**；交换链升级仍保持关闭（那与 HDR 路线绑定，是另一个坑）。

### ⑬ ⭐ HDR 现状判定（2026-10-04）：**Luma 的 HDR 在本作是"假生效"**

**四条硬证据**（全部来自本仓库源码 + 游戏目录实测）：

| # | 证据 | 含义 |
| --- | --- | --- |
| 1 | `main.cpp` DllMain 里 `swapchain_format_upgrade_type = None` | Luma **只在它为 `AllowedEnabled`** 时才把 backbuffer 换成 `r16g16b16a16_float`(scRGB) 或 `r10g10b10a2`(HDR10) 并设 HDR 色彩空间（`core.hpp:3137-3142`、`3341-3347`） |
| 2 | 同上 ⇒ `output_linear = false`、`output_pq_bt2020 = false`（`core.hpp:5685-5687`） | Luma **HDR 输出编码路径根本不会启动** |
| 3 | 本 mod 只带 **1 个**着色器（`Luma_MafiaDE_Sharpen.hlsl`）；**官方 Mafia III mod 带 25 个**（含 27KB 的 `Tonemap_0xF4D0E9C2`、`UI_Sprite`、`DecodeVideo`、`RearViewMirrorHUD`、`SniperScope`、TAA 三变体…） | Luma 的 HDR **靠替换游戏侧 tonemap/UI 着色器**把场景保持在线性 HDR；我们没有对象 ⇒ `TONEMAP_TYPE = Luma HDR (Vanilla+)` **空转**，游戏自己的 tonemap `0x916B1D65` 仍把画面压成 SDR |
| 4 | 游戏目录 `ReShade.ini` 里 `DisplayMode=1`（HDR） | 面板上"开着的 HDR"**只是 Luma 内部目标值**（ScenePeakWhite/PaperWhite…），不改变送到屏幕的信号 |

⇒ 即使只把交换链升级打开，在 (3) 之前结果也只是 **"SDR 装在 HDR 容器里"**（Luma 自己叫 `SDRInHDR`，明说是 dev 假对比模式）。

**真 HDR 需要的四件事（按依赖与工作量）**

| # | 事项 | 量级 | 关键约束 |
| --- | --- | --- | --- |
| 1 | 交换链升级（scRGB FP16） | 小（一个开关） | 当年因独占全屏死锁而关；但我们**现在已设 `prevent_fullscreen_state = true`**，值得重试。风险：OptiScaler/XeFG 对交换链格式敏感 |
| 2 | **游戏侧 tonemap 替换**（`0x916B1D65` 写成 HDR-aware HLSL） | **大（主要工作量）** | 参考同引擎 `Mafia III/Tonemap_0xF4D0E9C2.hlsl`（27KB）；RenoDX 已为 Mafia DE 做过 tonemap/HDR |
| 3 | 游戏侧 UI 着色器（`UI_Sprite` 等） | 中 | 否则 UI 会被 HDR 亮度放大/被 tonemap |
| 4 | **scRGB(FP16) vs HDR10 的取舍** | — | Luma 的 HDR10 输出上游仍是 TODO；**XeFG 只认 HDR10** ⇒ **在 Luma 里做 HDR ≈ 放弃 XeFG** |

**⇒ 两条路线，建议优先验证 B**

| 路线 | 做法 | 代价 | 能否保住 XeFG |
| --- | --- | --- | --- |
| **A. Luma 自研 HDR** | 做上面 1→2→3（重写本作 tonemap，工程量最大） | 高（tonemap 移植） | ❌ scRGB 与 XeFG 互斥（除非上游补 HDR10） |
| **B. RenoDX 做 HDR + Luma 做 DLSS** | 解决 ② 的共存崩溃；**RenoDX 走 HDR10** | 中（共存问题 / fork RenoDX 自编译） | ✅ **HDR10 正是 XeFG 要的** |

**结论：HDR 应该让 RenoDX 做，不该在 Luma 里做** —— 因为 Luma 的 HDR 是 scRGB FP16，天生与 XeFG 冲突；
而 RenoDX 的 HDR10 恰好是 XeFG 的食物。⇒ ② 的方向从"给 Luma 加 HDR"改为"**让 RenoDX 与 Luma 共存**"。

### ② HDR —— ✅ 已解决（2026-10-04）：RenoDX 改走 HDR10，与 Luma + XeFG 共存

**先纠正旧判据**：""Luma×RenoDX 同开必崩"" 是**错的**。实测四件同开（Luma + RenoDX + DLSS5 bridge + RenoDX NR）**满帧跑通、零崩溃**
（`resolve hooked 7952x / SR drawn 3963x` 精确 2:1、`nr[evals=1639]`、`fps≈55`）。那条一次性 cbuffer 断言
（`core.hpp:5290`）只是"别人占着槽位"的卫生警告，注释自己写了通常无害。

**真崩因：XeFG 与 RenoDX 默认输出的交换链格式不兼容**（E3，三件同开必闪退）

| 步 | 日志原文 | 含义 |
| --- | --- | --- |
| 1 | `[RenoDX] OnCreateSwapchain(swap: r8g8b8a8_unorm => **r16g16b16a16_float**, …)` | 游戏原本 8-bit SDR（XeFG 接受）；RenoDX 升级成 **FP16/scRGB**（`swapchain_v2.hpp:108-110` 的默认） |
| 2 | `[E] XeFG Log: Backbuffer format is not valid. Found 40.` | XeFG 只认 8-bit 或 **HDR10 (R10G10B10A2)** ⇒ 拒绝 |
| 3 | `XEFG_SWAPCHAIN_RESULT_ERROR_INVALID_ARGUMENT` → `creating plain DX12 swapchain` → `fg 80070005` | FG 交换链失败，回退也失败 |
| 4 | `IDXGIFactory::CreateSwapChain failed with error code 0x80070005` | 游戏拿不到交换链 ⇒ **闪退**（无 APPCRASH，属进程自行退出） |

⇒ 这正是"scRGB(FP16) 与 XeFG 互斥"那条铁律，**只是挡路的是 RenoDX 而不是 Luma**。
⛔ **旁路已被证伪（勿重试）**：`OptiScaler.ini [HDR] ForceHDR/UseHDR10 = true` **无效** —— OptiScaler 确实读到了设置
（`[I] HDR.UseHDR10: true`），但 **FG 交换链格式继承自游戏交换链，它覆盖不了**。

**解法（第一步）：fork RenoDX，把输出模式固定为 HDR10** —— 改动仅 +1 行 / −1 行，是第一次跑通用的版本；随后做成了设置项（见下）

| 文件 | 改动 |
| --- | --- |
| `src/games/mafiade/addon.cpp` | `DllMain` **+1 行**：`renodx::mods::swapchain::SetUseHDR10(true);`（与 `stalker2` / `wobblylife` / `absolum` 同位置） |
| `src/games/mafiade/common.hlsl` | `FinalizeOutput()`：`color /= 80.f;`（scRGB 线性，1.0 = 80 nit）→ `bt2020::from::BT709(color)` + `pq::EncodeSafe(color, 1.f)`（PQ，输入已是 nit） |

- **原色转换必须做**：`bt709::clamp::BT2020` 只是"进 BT2020 域钳掉负值再转回 BT709"（`src/shaders/color/clamp.hlsl:14-18`），
  输出仍是 **BT.709**；而 HDR10 容器是 **BT.2020**。上游所有 HDR10 路径都是 `bt2020::from::BT709 → pq::EncodeSafe`
  （`vrising/uberpost_*`、`windblown/fxaa_fsr1_*`、`wutheringwaves/swapchainproxy/*`、各作 `lutShaper`），devkit 标准路径同理
  （`draw.hlsl` 的 `SWAP_CHAIN_OUTPUT_PRESET_HDR10` 用 `compress/encoding_color_space = BT2020`）。
- 未改：`InvertFinalizeOutput`（仅 fireworks 彩蛋 pass 用，源码内已注明仍按 scRGB 约定）。

**构建（本机全流程已验证可复现）**

| # | 步骤 | 本机实测的坑 |
| --- | --- | --- |
| 1 | 取源码 | 无系统 git ⇒ 便携 MinGit（`logs\tools\mingit`）；走系统代理 `$env:HTTPS_PROXY=http://127.0.0.1:7890`（**不改 git config**）；仓库有 git-lfs 文件 ⇒ 需 `-c filter.lfs.*=` 覆盖 |
| 2 | submodule | 只需 7 个：reshade / Detours / json / frozen / gtl / Streamline / DLSS（DirectXTex、openexr、Imath **不用**）。⛔ 本机 **DLSS 拉不下来**（`Unable to find current revision`）⇒ 用 `codeload` 按钉住的 SHA 取 zip 覆盖 `external/DLSS` 即可（只要头文件） |
| 3 | 工具 | `scripts\setup-dev-env.ps1 -Install`（dxc/slangc/glslang/3migoto → `bin\`，并复制 SDK 的 fxc）；需 Windows SDK ≥ 10.0.26100.0（本机有） |
| 4 | 配置/编译 | VS 2022 BuildTools 自带 **cmake 3.31.6**：`cmake --preset vs-x64` → `cmake --build --preset vs-x64-release --target mafiade`（≈20 秒） |
| 5 | 部署 | `build.vs\Release\renodx-mafiade.addon64`（1,367,040 B）→ 游戏目录 `renodx-mafiade.addon64`；**上游原版留** `renodx-mafiade.addon64.upstream-2026.1004.53`（改名即回滚） |
| 6 | 留档 | 补丁 `logs\diag\renodx-fork\mafiade-hdr10.patch`（fork 版）、`…\mafiade-hdr10-upstream.patch`（从暂存索引导出）、PR 正文 `…\PR-mafiade-hdr10.md`、产物 `…\renodx-mafiade-hdr10.addon64`；源码树 `D:\AiWorkSpace\renodx`（分支 `feat/mafiade-hdr10`） |

**验证（E4，2026-10-04）**

```
[RenoDX]     OnCreateSwapchain(swap: r8g8b8a8_unorm => r10g10b10a2_unorm, …)
[RenoDX]     utils::swapchain::OnInitEffectRuntime(colorspace: hdr10_st2084)
[OptiScaler] Created Dx11wDx12SC: wrapper …, real11 …, fg12 …
[OptiScaler] XeFG_Dx12::Activate SetEnabled: true, result: XEFG_SWAPCHAIN_RESULT_SUCCESS (0)
[OptiScaler] XeFG_Dx12::Dispatch Interpolation count changed -1 -> 3        ← 4 倍插帧
[OptiScaler] IFeature_Dx11wDx12::Evaluate DLSS-NR: … (upscale ok: true, enabled: true)
[Luma]       resolve hooked 7946x, SR drawn 3968x（2:1）
```

⇒ **Luma(DLAA) + RenoDX(HDR10) + OptiScaler(XeFG 4x + OptiScaler NR) 同开跑通 = ② 的目标态**。

**已做成设置项（2026-10-04 第二轮）**：RenoDX overlay 新增 **`Output`** 段

| 设置 | 选项 | 默认 | 说明 |
| --- | --- | --- | --- |
| `Swap Chain Format` | `HDR10` / `scRGB` | **HDR10** | 内部即 `SetUseHDR10(value == 0)`（同 `wutheringwaves`）；键 **`Upgrade_UseSCRGB`**（与 `wutheringwaves`/`unrealengine` 同一个全局键 —— 语义与标签完全一致，有意复用），段 `Resource Upgrades`。格式在**交换链创建时**确定，所以改完要重启生效（alt-tab/改分辨率触发重建亦可） |
| `Output Dither` | `Off` / `On` | **On** | 10-bit HDR10 输出前的 ±0.5 LSB 逐像素 + 逐帧抖动（键 `OutputDither`，段 `Output`；镜射 `renodx::draw::SwapChainPass` 的 `swap_chain_output_dither_*` 块）；scRGB(FP16) 路径不抖 |

两个设置都带 `is_visible = []() { return settings[0]->GetValue() >= 2; }` ⇒ **只在高级设置模式下可见**（沿用上游 `Upgrade_*` 惯例）。

⚠️ **关键设计**：shader 跟的是**真实交换链格式**、不是设置值 —— `OnInitSwapchain` 里用
`device->get_resource_desc(swapchain->get_back_buffer(0))` 读实际格式，写进 `shader_injection.swap_chain_output_preset`
（1 = HDR10，2 = scRGB，与 `renodx::draw::SwapChainPass` 的预设编号一致）。
否则切 scRGB 时 shader 会立刻换编码、而交换链还是 HDR10 ⇒ 画面瞬间错色（看着像坏了，实为伪故障）。

**遗留（都不影响可用）**
- BT.2020 转换 + PQ + 抖动已实机验证；**scRGB 模式 ✅ 已复测**（16:51 轮：overlay 切 scRGB + 重启 ⇒ `=> r16g16b16a16_float` + `extended_srgb_linear`，留档 `logs\diag\20261004-165551_upstream-conformant-OK`）
- **HDR10 轮也已留档**（17:00 轮，用户确认正常）：`=> r10g10b10a2_unorm` + `hdr10_st2084`、`XeFG_Dx12::Activate … SUCCESS`、**正常退出**（`Unregistered add-on "RenoDX"`）、错误/断言 0 ⇒ `logs\diag\20261004-170334_upstream-conformant-HDR10-OK`
  ⇒ **上游规范版的两条路径都验证通过**（这是 PR 正文里那份"手工验证"的实测依据）
  ⚠️ ReShade.log **每次运行覆盖** ⇒ 每轮跑完**立刻** `collect.ps1`，否则证据丢（E5 那轮就是这样只剩 fork 版留档）
- ✅ **已清理（2026-10-04）**：① 游戏目录里 0 字节的 **`dxgi.dll.original` 已删除**（定时炸弹：谁把它改回 `dxgi.dll`，游戏就会加载空 DLL 直接崩）；② `ReShade.ini` 里两个**废弃键** `MafiaDE_OutputDither` / `MafiaDE_SwapChainFormat` 已删（备份 `logs\diag\ReShade.ini.pre-cleanup`，BOM/CRLF 原样保留），`[renodx]` 段现在只剩 4 个有效键：`OutputDither` / `SettingsMode=2`（高级模式 ✓ 所以两个新设置可见）/ `SwapChainForceBorderless` / `Upgrade_UseSCRGB=0`（HDR10）；③ 4 个调试遗留的 DLL 副本（`d3d11.dll.off-wronglayer{,2,3}`、`dxgi.dll.luma-reshade`，共 **21.3 MB**）已删 —— 删前核对过 SHA256 与活体 `d3d11.dll` **完全相同**（`A6EE4694…`）⇒ 纯副本、零损失，需要时 `Copy-Item d3d11.dll <目标名>` 即可复原；④ **2025-06-15 的 `dxgi.log`**（7,311 B，头几行是 `ReShade 4.6.1 (2020 build) loaded from "dxgi.dll"` ⇒ 当年"ReShade 挂错层"那批考古遗留，16 个月没再动过）已删。**游戏目录现在只剩该有的注入层与日志**：`d3d11.dll`（Luma ReShade 宿主）+ `dxgi.dll`（OptiScaler）
- fireworks 彩蛋 pass 的 `InvertFinalizeOutput` 仍是 scRGB 约定（只在彩蛋场景出现）
- OptiScaler NR 仍 `MaxRatio = auto`（那份调优教程建议 6）；`[XeFG] HighResMV = auto`（本作 MV 是渲染分辨率 ⇒ 可显式 true）
- ✅ **上游化已执行（2026-10-04）**：分支 `feat/mafiade-hdr10`（基线 `main@da608c4`，已用 `git ls-remote` 确认仍是上游 tip），**4 文件 / +89 −4**，已按上游规范改写并暂存：
  去 `[fork]`/日期标记、`EncodeSwapChainOutput` 合回 `FinalizeOutput`（**不新增单次使用 helper**，符合 `AGENTS.md:48` / `CXX_STYLE.md:185`）、改用上游 `swap_chain_output_dither_bits` + `exp2(bits)-1` 抖动公式、
  加 `is_visible` 高级门控、键改 `Upgrade_UseSCRGB`、`add_setting` 沿用本文件既有风格。
  `git diff --cached --stat` = +89/−4 ✓；行尾按各文件索引属性分别保持（`i/crlf, i/lf, i/crlf, i/lf`）⇒ **无全文件假 diff**；编译通过（cmake preset，13.7 s）。
  物料：`logs\diag\renodx-fork\mafiade-hdr10-upstream.patch` + `PR-mafiade-hdr10.md`（标题/正文可直接粘贴）。
  ✅ **已提交并开 PR（2026-10-04）**：提交 `805a28f`（作者 `williamstosh <403302945@qq.com>`，单行 Conventional Commit，与仓库现有风格一致）已推到 `williamstosh/renodx` 的 `feat/mafiade-hdr10`；
  **PR = https://github.com/clshortfuse/renodx/pull/696**（MERGEABLE ✓，4 文件 **+89/−4** ✓，正文即 `PR-mafiade-hdr10.md`，已核对含两轮实测日志 ✓）。
  ⛔ 本机两个坑（下次照抄）：
  ① 助手侧 `git commit` **被环境安全策略拦截**（`add`/`status`/`log`/`ls-remote` 放行，只有 commit 被改写拦截 ⇒ 不绕过）⇒ 提交由用户在自己终端用
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*` **环境变量**完成（**不改 git config** ✓）；
  ② 开 PR 走 **GitHub CLI**（`winget install --id GitHub.cli -e` ✓）：先 `gh auth login --web`（设备码，一次性 ✓），再
  `gh pr create --repo clshortfuse/renodx --base main --head williamstosh:feat/mafiade-hdr10 --title "…" --body-file "…\PR-mafiade-hdr10.md"` ——
  ⚠️ `gh` 要求 **PATH 里有 git**（本机只有便携 MinGit：`$env:PATH='…\logs\tools\mingit\cmd;'+$env:PATH` ✓）且需 `HTTPS_PROXY=http://127.0.0.1:7890` ✓。
  ✅ **上游规范版已实机复测（2026-10-04）**：HDR10 轮（默认）用户确认功能与观感正常、XeFG 激活；scRGB 轮（overlay 手切后重启）实测 `r16g16b16a16_float` + `extended_srgb_linear` ⇒ 两条路径都对，`FinalizeOutput` 跟随真实交换链的设计成立。
  ⚠️ 本机 MinGit **无 git-lfs**：`git add/diff` 会被 `clean filter 'lfs' failed` 整条中断 ⇒ 用环境变量
  `GIT_CONFIG_COUNT=2 / GIT_CONFIG_KEY_0=core.autocrlf / GIT_CONFIG_KEY_1=filter.lfs.required / GIT_CONFIG_VALUE_1=false` 绕过（不写任何 config）。

- ✅ **Luma 上游 PR 已开（2026-10-05）**：分支 `feat/mafiade`（基线 `main@5d7ee54`），**14 文件 / +4625 −2**，
  **PR = https://github.com/Filoppi/Luma-Framework/pull/225**（MERGEABLE ✓）。内容 = 新增 Mafia: DE 游戏 mod
  （main.cpp 2860 行、REPORT.md、docs 反汇编 ×2、hlsl ×4、vcxproj ×3）＋ 框架级 **`SDR_OUTPUT_TRANSFORM`**
  （`core.hpp` +2 / `Luma_DisplayComposition.hlsl` +24−2；Mafia DE 依赖它，**默认 0 ⇒ 不改变任何既有游戏**）。
  操作要点（下次照抄）：
  ① `luma-build` 原本**没有 `.git`**（tarball 解压的工作树）⇒ `git init -b main` ＋ `git remote add upstream`
     ＋ `git fetch --depth 1 upstream main`（65 s / 93 MB）＋ `git update-ref refs/heads/main upstream/main`
     ＋ **`git reset --mixed`** ⇒ 索引 = 上游快照而**工作树不动**，`git status` 直接列出全部本地改动；
  ② **工具集**：vcxproj 交上游必须是 `v145`、本机只有 v143 ⇒ 在脚本里加 `/p:PlatformToolset=v143` 覆盖
     （已验证：不传该参数报 `MSB8020 无法找到 v145`，传了 `BUILD_EXIT=0`）——**不要改 vcxproj 的工具集**；
  ③ **上游化清洗**：去 `[LOCAL]` 前缀 ×6、去日期标记 ×2；`LUMA_TEMPLATE_BIN_PATH` → `LUMA_MAFIA_DE_BIN_PATH` ×8
     （对齐上游 `LUMA_MAFIA_II_DE_BIN_PATH` 命名）；本机路径 → 通用表述（main.cpp ×1、docs 头部 ×2）；
  ④ 补 `...vcxproj.user`（上游 Mafia II/III 都有；被 `.gitignore` 忽略 ⇒ 必须 `git add -f`）；
  ⑤ `docs/disasm-*.txt` 原是 **UTF-16 LE**（git 判为二进制、diff 不显示）⇒ 转 UTF-8 后成正常文本；
  ⑥ fork：`gh repo fork Filoppi/Luma-Framework --clone=false --default-branch-only`（**别加 `--remote`**，与仓库参数互斥）；
     push 走系统 **Git Credential Manager**（`credential.helper = manager`）直接成功，无需 `gh auth setup-git`；
  ⑦ **本次 `git commit` 未被安全策略拦截**（上次 RenoDX 被拦）；身份仍走 `GIT_AUTHOR_*`/`GIT_COMMITTER_*` 环境变量，不写 config。
  ⚠️ 留在 PR 外的本地件（**别误提**）：`atl_compat.h`、`shader_compiler.hpp`、`Graphics Analyzer` ×2、
  `build*.bat` / `dev.bat` / `pub.bat`、`CODEBUDDY.md`、`Scripts/*`、`Tools/*`、`.gitignore` 的 `logs/`。

**诊断工装（本次新建，可复用）**：`Scripts\diag\combo.ps1`（五组件组合开关，带游戏运行守卫 + 状态快照）、
`Scripts\diag\collect.ps1`（一键采集日志/崩溃签名/WER 模块清单并打印摘要）

**⚠️ 改 vault 笔记的纪律与工装** → 见上文「⛔ 改文档/笔记的铁律 + 安全改文工装」
（`Scripts\tools\text-guard.ps1`：`snapshot` / `verify` / `restore` / `scan`）。
