# img2text — 视觉桥接 Skill（给纯文本 LLM 装眼睛）

> 让 **DeepSeek V4 Flash** 等纯文本模型"看图"的 Agent Skill。
> 图片经旁路视觉模型（GLM-4.6V-Flash 免费 / qwen3-vl-plus）转成结构化描述，
> 主模型基于视觉证据推理 —— Claude Code 与 Codex **双平台通用**。

```
图片/截图 → img2text skill
    ├── 自动分类（PIL 特征：文档→OCR / UI→审查 / 自然图→描述）
    ├── 多 Provider（zhipu 免费 + aliyun，故障转移 + 熔断）
    ├── verify 双模型投票（关键场景交叉验证）
    ├── 结构化输出（text_blocks/elements/bbox/confidence/注入标记）
    ├── SHA256 缓存（同图同问秒回）+ 可观测性日志（JSONL）
    └── → DeepSeek 主模型推理（基于视觉证据，不靠猜）
```

## 为什么需要

DeepSeek V4 Flash 是纯文本模型 —— API 实测拒绝图片输入（`HTTP 400 unknown variant image_url`）。在 Claude Code / Codex 中：

- 用户贴图、截图检查、OCR、UI 审查 —— 模型全部"看不见"
- 业界解法即本 Skill 的"视觉桥接"（Vision Bridge）：旁路视觉模型把图转成文字，主模型继续工作

## 能力清单

| 能力 | 说明 |
|------|------|
| `--mode auto`（默认） | PIL 特征自动分类：白底低饱和→OCR / 深色高饱和或边框密集→UI 审查 / 多色低边框→描述 / 低置信→视觉自判 |
| `--mode ocr` | 完整转录（中/英/数字/符号/表格，保留格式） |
| `--mode ui-review` | UI/UX 审查（对齐/间距/截断/对比度/状态/层级，逐条列位置） |
| `--mode verify` | **双模型投票**：zhipu+aliyun 并行，一致采信、降级明确标记"仅供参考"（GLM 状态判断有漂移，关键判断必须 verify） |
| `--format json` | 结构化输出：`{request_id, image_id, scene_summary, text_blocks[{text,bbox,confidence}], elements[{type,label,bbox,state}], warnings, content_type}` |
| 注入安全 | 图片内指令文字标记 `content_type: untrusted_visual_text` + `injection_keywords` |
| 可观测性 | `~/.cache/img2text/logs/vision-YYYYMMDD.jsonl`：trace_id/request_id/耗时/token/错误 |
| 工程化 | SHA256 缓存（key=图+问题+模式，防记忆污染）、熔断（5 次失败冷却 60s）、curl 重试、魔数校验、路径归一化（Windows/MSYS） |

## 安装（双平台）

```bash
# 1. 复制 skill 到 Claude Code（或 junction 链接）
mkdir -p ~/.claude/skills
cp -r skill ~/.claude/skills/img2text

# 2. Codex（CLI 或桌面版）—— junction 共享同一套
cmd //c mklink /J "%USERPROFILE%\.codex\skills\img2text" "%USERPROFILE%\.claude\skills\img2text"
cmd //c mklink /J "%USERPROFILE%\.agents\skills\img2text" "%USERPROFILE%\.claude\skills\img2text"

# 3. 规则文件（可选但强烈建议）：复制到对应位置
cp skill/docs/claude-rules.md ~/.claude/CLAUDE.md    # Claude Code 硬规则
cp skill/docs/codex-rules.md   ~/.codex/AGENTS.md    # Codex 硬规则

# 4. 视觉子 agent（可选）：批量/多图场景任务隔离
cp skill/agents/visual-reader.md ~/.claude/agents/visual-reader.md

# 5. API Key（视觉模型）
echo '智谱key' > ~/.zhipu_key        # GLM-4.6V-Flash（永久免费，https://open.bigmodel.cn）
echo '百炼key' > ~/.dashscope_key    # qwen3-vl-plus（按量，阿里云百炼）
```

## 使用

```bash
# 日常：贴图自动分流
bash ~/.claude/skills/img2text/scripts/img2text.sh 图片.png

# 关键单据/数字 → 双模型交叉验证
bash ~/.claude/skills/img2text/scripts/img2text.sh 发票.png --mode verify

# UI 逻辑审查
bash ~/.claude/skills/img2text/scripts/img2text.sh 截图.png --mode ui-review

# 结构化输出（供程序消费）
bash ~/.claude/skills/img2text/scripts/img2text.sh 图.png --format json

# 状态查询
bash ~/.claude/skills/img2text/scripts/img2text.sh --providers
```

## 质量保障（42 用例全过）

本仓库 `tests/` 是视觉链路的**分层测试与验收体系**（pytest 42/42 通过，seed 固定可重放），测试方法论见 [TEST_PLAN.md](TEST_PLAN.md)（17 章：六层链路/OCR 矩阵/UI/DOM 真值/多图片记忆污染/注入安全/故障注入/并发/分级指标）。测试揪出并修复的真实缺陷：

- **P1 缓存污染**：同图不同问法命中旧答案 → key=hash(图+问题+模式)
- **P1 预处理破坏 UI 语义**：autocontrast 改变深色 UI 颜色致 disabled 误判 → 仅放大
- P2 空输出被缓存 / 批量限流 / 状态判断漂移（→ verify 投票）

```bash
python generators/generate_fixtures.py && python generators/generate_t1_fixtures.py
python -m pytest tests/ -q    # 42 passed
```

## 目录结构

```text
skill/              本 Skill 本体（SKILL.md / 脚本 / 子 agent / 双平台规则）
tests/              分层测试（42 用例）
generators/         测试夹具生成器（seed 固定）
ground_truth/       标准答案
TEST_PLAN.md        测试方法论（17 章）
artifacts/          评测报告
```

## 同类参考

- [deepseek-vision-skill](https://github.com/iuiaeng2005/deepseek-vision-skill) — DeepSeek + GLM-4V-Flash 桥接（最早的同构方案）
- [unblind](https://github.com/Santazuki/unblind) — 7 Provider 故障转移 + 缓存防御架构
- [cc-VisionRouter](https://github.com/Able-rip/cc-VisionRouter) — Claude Code 透明代理分流（代理层路线）

## 许可

MIT

---

**如果这套视觉桥接 Skill 对你有帮助，欢迎 ⭐ Star 支持！**
