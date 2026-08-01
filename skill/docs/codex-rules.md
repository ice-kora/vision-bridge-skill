# Codex 环境规则

## 模型无视觉能力（重要）

当前模型（deepseek-v4-flash 等纯文本模型）**没有视觉能力**（API 实测拒绝/忽略 image 输入）。当你需要"查看"图片时（用户贴图、截图、检查 UI/立绘/设计稿效果、OCR 提取文字等）：

1. **必须**调用 `bash ~/.claude/skills/img2text/scripts/img2text.sh <图片路径或URL> ["问题"]` 把图片转成文字描述后再继续（详见 img2text 技能的 SKILL.md）；
2. 图片在剪贴板时先保存为文件再调用；
3. img2text 返回的是视觉模型（GLM-4.6V-Flash 免费）的文字描述，作为你看图的唯一依据，禁止凭空猜测图片内容；
4. 高级用法：`--mode ocr`（文字提取）/ `--mode ui-review`（UI 审查）/ `--mode verify`（双模型交叉验证）/ `--no-cache`（跳过缓存）；
5. 对"验证渲染效果/找瑕疵"类任务，可先用程序化手段（PIL 像素统计、边缘检测、尺寸/比例检查）做客观检查，再结合 img2text 描述。

## Skill 说明

`img2text` skill 已安装在 `~/.codex/skills/img2text`（junction 指向 `~/.claude/skills/img2text`，与 Claude Code 共用同一套脚本）。配置 API key：`~/.zhipu_key`（智谱，免费）。
