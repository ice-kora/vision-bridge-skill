# Vision Bridge QA — 无视觉模型视觉链路的测试与验收体系

> 给 DeepSeek V4 Flash 等纯文本模型"装眼睛"（img2text 视觉桥接）的**分层测试与验收方案**。
> 包含：程序生成测试夹具（PIL 合成 + Ground Truth）、DOM 真值网页对比、多图片差异与记忆污染测试、
> 故障注入（无效 key / 熔断）、并发不串线、图片提示词注入安全、结构化输出契约、可观测性日志验证。

## 背景

DeepSeek V4 Flash（`deepseek-v4-flash`）是纯文本模型 —— API 实测拒绝 image 输入（`HTTP 400 unknown variant image_url`）。为让它在 Claude Code 中"看图"，搭建了视觉桥接链路：

```
图片/截图 → img2text.sh v2/v3（采集+预处理+自动分类+缓存+熔断）
    → 视觉模型（智谱 GLM-4.6V-Flash 免费 / 阿里 qwen3-vl-plus）
    → 结构化输出（text_blocks/elements/bbox/confidence/注入标记）
    → 可观测性日志（JSONL：trace_id/耗时/token）
    → DeepSeek V4 Flash 主模型推理
```

本仓库是这套链路的**测试与验收体系**（`D:\code\pyCode\game` 业务项目全程只读）。

## 测试过程概述

### 分层测试（按方案六层拆分）

| 层 | 测试内容 | 用例 |
|---|---|---|
| 采集/输入契约 | 损坏文件（截断/伪装/空）拒绝、路径归一化、大小限制 | 3 |
| OCR | 简体/繁体/英文/数字/符号/小字/低对比/倾斜/模糊/噪声/混排/渐变 + 关键数字精确匹配 + 表格单元格 | 15 |
| UI 元素 | 金币读取、按钮 disabled 状态（verify 双模型+多数采样）、警告图标、计数、空间关系 | 5 |
| 结构化输出 | JSON 必填字段、bbox 合法性、confidence 范围、content_type 注入标记 | 2 |
| 可观测性 | JSONL 日志字段完整性（trace_id/request_id/耗时/token） | 1 |
| 拒答 | 全黑/全白/随机噪声不虚构内容 | 3 |
| 注入安全 | 图片指令文字识别为内容（untrusted_visual_text 标记） | 2 |
| DOM 真值 | 真实 HTML 页面 + Playwright 截图，视觉结果 vs DOM 标准答案 | 4 |
| 多图片 | A/B 找不同、**记忆污染**（先问有红点的 A 再问无红点的 B） | 3 |
| 故障注入 | 无效 key 优雅失败、连续失败熔断触发 | 2 |
| 并发 | 5 路并行调用结果不串线 | 1 |
| 一致性 | 同图 3 种问法结果一致 | 1 |

**结果：42 / 42 通过（pytest，seed 固定可重放）**

### 测试揪出并修复的真实缺陷

| 等级 | 缺陷 | 修复 |
|---|---|---|
| P1 | **缓存污染**：同图不同问法命中旧答案（命中方案 §4.6 视觉记忆污染场景） | 缓存 key = hash(图片+问题+模式) |
| P1 | **预处理破坏 UI 语义**：autocontrast 改变深色 UI 颜色，导致按钮 disabled 状态误判 | 预处理仅放大、不做对比度增强 |
| P2 | 视觉 API 空输出被写入缓存 → 永久空结果 | 空输出不缓存、计入失败 |
| P2 | 批量连续调用触发免费 API 限流 | 测试侧指数退避重试（链路侧已有熔断） |
| P3 | 模型状态判断偶发漂移（GLM 单跑 50/50） | verify 双模型投票 + 多数采样；降级单跑明确标记"仅供参考" |

### 已知限制（P1，如实记录）

- 免费 API 限流为常态风险（1 并发）
- 关键 UI 状态判断存在偶发漂移，**必须双模型投票采信**
- 图片注入的"执行层阻断"依赖上层规则约束（识别层已正确标记 untrusted_visual_text）

## 快速开始

```bash
# 1. 生成测试夹具（seed 固定，可复现）
python generators/generate_fixtures.py
python generators/generate_t1_fixtures.py   # 需 Playwright（复用任意项目的 node_modules 即可）

# 2. 运行全部测试（42 条，约 3 分钟）
python -m pytest tests/ -q

# 3. 配置被测链路（img2text）
#    ~/.zhipu_key     智谱 API Key（GLM-4.6V-Flash 永久免费）
#    ~/.dashscope_key 阿里百炼 API Key（qwen3-vl-plus）
```

## 目录结构

```text
fixtures/         测试图片（generated 合成 / webpages DOM 页 / corrupted 损坏文件）
ground_truth/     标准答案（JSON，测试只传图片+问题，GT 由测试程序比对）
generators/       夹具生成器（PIL 合成 + Playwright 截图，seed 固定）
tests/            pytest 分层测试（12 个测试文件 42 用例）
artifacts/        测试报告与证据
```

## 相关

- 被测链路：img2text（视觉桥接脚本，Claude Code skill + visual-reader 子 agent 架构）
- 参考方案：[unblind](https://github.com/Santazuki/unblind) / [cc-VisionRouter](https://github.com/Able-rip/cc-VisionRouter) / [deepseek-vision-skill](https://github.com/iuiaeng2005/deepseek-vision-skill)

## 许可

MIT

---

**如果这个测试体系对你有帮助，欢迎 ⭐ Star 支持！**
