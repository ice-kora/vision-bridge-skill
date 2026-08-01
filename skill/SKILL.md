---
name: img2text
description: >
  无视觉模型的看图工具（Vision Bridge）：把图片转成文字描述，
  供 DeepSeek 等纯文本主模型"看图"。当需要查看/描述图片、OCR
  文字提取、检查截图/UI/设计稿/立绘效果、评估图片质量或瑕疵时
  必须使用本技能。

metadata:
  author: ice-kora
  version: "1.0.0"
  tags:
    - vision
    - ocr
    - image
    - bridge
    - deepseek
---

# img2text —— 无视觉模型的眼睛（v2）

## 何时必须使用

主模型（deepseek-v4-flash）**没有视觉能力**。出现以下情况时，**必须**调用本技能把图片转成文字描述，禁止凭空猜测图片内容：

- 用户贴图 / 拖入图片
- `Read` 图片文件返回 `[Unsupported Image]` 或图像内容无法理解
- 需要检查截图、UI、弹窗、立绘、设计稿的视觉效果
- 需要 OCR 提取图片中的文字（含中文、表格、公式）
- 需要对图片做质量/瑕疵评估（毛边、锯齿、色差、变形）

## 用法

```bash
bash ~/.claude/skills/img2text/scripts/img2text.sh <图片路径或URL> ["问题(可选)"] [选项]
```

- 本地路径：绝对路径或相对路径（Windows 路径如 `C:\...` 需加引号）
- URL：`https://...` 直接传入
- 输出为视觉模型的文字描述，**作为看图的唯一依据**

### 模式（默认 auto 自动分流）

| 模式 | 用途 | 说明 |
|------|------|------|
| `--mode auto`（默认） | 自动分类 | PIL 程序化特征判断：白底低饱和→**OCR**；深色高饱和/边框密集→**UI 审查**；多色低边框→描述；低置信→视觉模型自判 |
| `--mode ocr` | 文字提取 | 完整转录（含表格），保留格式 |
| `--mode ui-review` | UI/UX 审查 | 对齐/间距/截断/对比度/风格统一/层级，逐条列位置；**逻辑审查建议配合 `--mode verify` 或 `IMG2TEXT_CHAIN=aliyun`（qwen3-vl-plus 的 UI/逻辑审查显著强于 GLM）** |
| `--mode verify` | 双模型投票 | zhipu+aliyun 并行，一致采信/不一致双输出；关键单据高可靠场景 |
| `--format json` | 结构化输出 | 主 agent 可编程消费 |
| `--no-cache` | 跳过缓存 | 强制重新识别 |
| `--providers` | 状态查询 | 列出 provider 与 key 配置状态 |

**UI 与纯文字的判断**：默认 auto 已自动分流（程序化特征 + 视觉确认）；无法区分时（unknown）由视觉模型自适应判断（一条 prompt 同时处理三种类型）。

## API Key 配置（一次性）

注册 https://open.bigmodel.cn（智谱，免费）→ 控制台创建 API Key：

```bash
echo '你的key' > ~/.zhipu_key
```

或设置环境变量 `ZHIPU_API_KEY`。未配置时脚本会提示且退出码 2。

## 模型切换（可选）

环境变量 `IMG2TEXT_MODEL`，默认 `glm-4.6v-flash`（免费，视觉推理更强，推荐）：

| 模型 | 说明 |
|------|------|
| `glm-4.6v-flash`（默认） | 免费，128K 上下文，OCR 与视觉推理强 |
| `glm-4v-flash` | 免费，老版基础识图 |
| `glm-4.6v` | 付费（$0.80/M），中文文档/OCR 精度最佳 |
| `qwen3-vl-32b`（未来接入） | 付费（$0.52/M），性价比甜点 |

```bash
IMG2TEXT_MODEL=glm-4.6v bash ~/.claude/skills/img2text/scripts/img2text.sh test.png
```

## 对渲染效果类任务的补充规则

弹窗、UI、立绘等"视觉质量"评估，先做**程序化客观检查**再结合 img2text 描述：

1. 尺寸/比例检查（PIL）：`Image.open(path).size`，核对预期宽高比
2. 像素级检查：颜色直方图（主题色）、边缘检测（锯齿/毛边）
3. 对比验证：渲染预览合成（如把透明 PNG 贴到目标背景上）后交给 img2text 评估

## 注意事项

- 免费模型限 1 并发，个人使用足够；图片 ≤5MB
- 图片在剪贴板时：先截图/保存为文件再调用
- API 不可用时的兜底：跳过视觉环节，告知用户"当前无法查看图片"
- 不要修改主模型配置（ANTHROPIC_*）；本技能只做图片→文字的旁路
