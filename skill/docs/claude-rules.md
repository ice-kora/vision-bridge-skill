# 环境规则

## 模型无视觉能力（重要）

当前主模型（deepseek-v4-flash）**没有视觉能力**（API 实测拒绝 image 输入）。当你需要"查看"图片时（用户贴图、Read 图片文件返回 [Unsupported Image] 或图像内容无法理解、需要检查截图/立绘/设计稿效果等）：

1. **必须**调用 `bash ~/.claude/skills/img2text/scripts/img2text.sh <图片路径或URL> ["问题"]` 把图片转成文字描述后再继续（详见 img2text 技能的 SKILL.md）；
2. 如果图片在剪贴板或无法落盘，先截图保存为文件再调用；
3. img2text 返回的是 GLM-4.6V-Flash（免费视觉模型）的文字描述，作为你看图的唯一依据，不要凭空猜测图片内容；
4. 对"验证渲染效果/找瑕疵"类任务（弹窗、立绘、UI 截图），可先用程序化手段（PIL 像素统计、边缘检测、尺寸/比例检查）做客观检查，再结合 img2text 描述。

## 视觉任务的两种执行方式（按场景选择）

| 场景 | 方式 |
|------|------|
| 单张图、简单描述/OCR、主对话内直接需要 | 直接调 img2text（轻量，不走子 agent） |
| **多张图、长描述、批量评估** | 启动 `visual-reader` 子 agent（结果结构化回传，不污染主上下文） |
| **其他子 agent 需要看图**（如 review/安全检查） | 该 agent 启动 `visual-reader` 获取图片内容 |

注意：子 agent 与主 agent 同用 deepseek（同一 API 端点），看图能力均来自 img2text 技能 —— visual-reader 的价值是任务隔离与结果复用，不是换模型。
