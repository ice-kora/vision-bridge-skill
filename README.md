# 视觉链路测试与验收方案 — 无视觉模型的"眼睛"怎么测

> **本仓库的核心是《[TEST_PLAN.md](TEST_PLAN.md)》：一套完整的「无视觉模型 + 视觉桥接链路」测试与验收方案（17 章）** —— 从六层链路拆分、测试数据设计、核心测试矩阵（OCR/UI/空间/计数/表格/多图片）、可信性与幻觉测试、图片提示词注入安全、鲁棒性/一致性/性能/故障注入，到 SLG 游戏专项、用例分级（T0/T1/T2）、质量指标门槛、缺陷分级、证据规范与验收流程。
>
> `tests/` 是本方案的一次**完整落地验证**：pytest 42 用例全过，证明方案可执行、可复现。

## 为什么需要这份方案

DeepSeek V4 Flash 等纯文本模型**没有视觉能力**（API 实测拒绝 image 输入）。业界通用解法是"视觉桥接"（Vision Bridge）：图片经旁路视觉模型转成文字/结构化数据，再交给主模型推理。但桥接链路引入了一整条新的故障面：

- 图片采集/预处理会不会破坏语义？（实测：autocontrast 会改变深色 UI 颜色，导致按钮 disabled 状态误判）
- 视觉结果怎么结构化、怎么防幻觉、怎么标记"看不到"？
- **图片里的恶意文字会不会变成指令？**（注入安全是最高风险项）
- 缓存会不会污染？（实测：同图不同问法命中旧答案）
- 限流/超时/熔断/并发怎么测？

这份方案把这些问题拆成 **6 层 × 5 类数据 × 12 个测试维度 × 3 级用例**，并给出可量化验收门槛。

## 方案结构（17 章速览）

| 章节 | 内容 |
|------|------|
| §1-2 | 测试目标、**六层链路拆分**（采集→预处理→视觉模型→结构化→推理→业务执行） |
| §3 | 三类测试数据：程序生成（带 Ground Truth）、**DOM 真值页**、真实图片集 |
| §4 | 核心测试矩阵：OCR / UI 元素 / 空间关系 / 计数 / 表格图表 / **多图片记忆污染** |
| §5 | 可信性与幻觉：不存在对象拒答、不可读图片、**置信度校准** |
| §6 | **图片提示词注入安全**（最高风险）：识别为内容 + `untrusted_visual_text` 标记 + 执行层阻断 |
| §7-8 | 鲁棒性（图像变换一致性）、一致性（多问法/错误引导） |
| §9 | 性能（p50-p99）/ 并发（串线/缓存污染）/ **故障注入**（429/超时/JSON 截断） |
| §10 | 网页 SLG 游戏专项（剧情/小剧场/属性/行动事件/插画/语音视觉状态） |
| §11-14 | 用例分级（T0 冒烟 40 / T1 回归 220 / T2 全量 500+）、质量指标门槛、缺陷分级、失败证据规范 |
| §15-17 | 六阶段执行流程、推荐目录结构、最终报告结构与结论标准（PASS/CONDITIONAL PASS/FAIL） |

## 落地验证（本仓库 tests/，42/42 通过）

方案 §11 的 T0 冒烟要求"至少 40 条" —— 本仓库实现了 **42 条**：

| 维度 | 用例数 | 关键验证点 |
|------|-------|-----------|
| OCR（13 类图像条件 + 关键数字 + 表格） | 15 | 1280 vs 1230、18/30 vs 18/80、中英繁混排 |
| UI 元素/状态/空间 | 5 | disabled 状态（**verify 双模型 + 多数采样**） |
| 结构化输出契约 | 2 | 必填字段 / bbox 合法性 / confidence 0-1 |
| 可观测性日志 | 1 | trace_id/request_id/耗时/token |
| 拒答（不可读图） | 3 | 全黑/全白/噪声不虚构 |
| 图片注入识别与标记 | 2 | `content_type: untrusted_visual_text` |
| 输入契约（损坏文件） | 3 | 截断/伪装/空文件拒绝 |
| DOM 真值页 | 4 | HTML + Playwright 截图 vs DOM 标准答案 |
| 多图片差异 + 记忆污染 | 3 | A 有红点 / B 无红点 / B 不沿用 A 的结论 |
| 故障注入 | 2 | 无效 key 优雅失败、连续失败熔断 |
| 并发 | 1 | 5 路并行不串线 |
| 一致性 | 1 | 同图 3 种问法结果一致 |

**测试揪出并修复的真实缺陷**（这就是方案的价值）：

| 等级 | 缺陷 | 修复 |
|------|------|------|
| P1 | 缓存污染：同图不同问法命中旧答案 | 缓存 key = hash(图片+问题+模式) |
| P1 | 预处理 autocontrast 破坏 UI disabled 语义 | 预处理仅放大、不做对比度增强 |
| P2 | 视觉 API 空输出被写入缓存 → 永久空 | 空输出不缓存、计入失败 |
| P2 | 批量连续调用触发免费 API 限流 | 指数退避重试（链路侧熔断） |
| P3 | 模型状态判断偶发漂移 | verify 双模型投票 + 降级明确标记 |

完整评测报告见 [`artifacts/latest/report-final.md`](artifacts/latest/report-final.md)。

## 快速开始（重放 42 条用例）

```bash
# 1. 生成测试夹具（seed 固定，可复现）
python generators/generate_fixtures.py
python generators/generate_t1_fixtures.py   # 需 Playwright（复用任意项目的 node_modules 即可）

# 2. 运行全部测试（42 条，约 3 分钟）
python -m pytest tests/ -q

# 3. 被测链路配置（img2text）
#    ~/.zhipu_key     智谱 API Key（GLM-4.6V-Flash 永久免费）
#    ~/.dashscope_key 阿里百炼 API Key（qwen3-vl-plus）
```

## 目录结构

```text
TEST_PLAN.md          方案全文（17 章，本仓库核心）
fixtures/             测试图片（generated 合成 / webpages DOM 页 / corrupted 损坏文件）
ground_truth/         标准答案（JSON，测试只传图片+问题，GT 由测试程序比对）
generators/           夹具生成器（PIL 合成 + Playwright 截图，seed 固定）
tests/                pytest 分层测试（42 用例）
artifacts/            测试报告与证据
```

## 参考

- [unblind](https://github.com/Santazuki/unblind) — 视觉桥接防御架构
- [cc-VisionRouter](https://github.com/Able-rip/cc-VisionRouter) — Claude Code 透明代理分流
- [deepseek-vision-skill](https://github.com/iuiaeng2005/deepseek-vision-skill) — DeepSeek + GLM-4V-Flash 桥接

## 许可

MIT

---

**如果这份方案/验证对你有帮助，欢迎 ⭐ Star 支持！**
