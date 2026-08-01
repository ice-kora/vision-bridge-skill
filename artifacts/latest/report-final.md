# 最终测试报告 — DeepSeek V4 Flash 视觉增强链路（T0 + T1）

- **日期**: 2026-08-02
- **被测**: img2text.sh v3（结构化输出 + 可观测性 + 注入标记）
- **视觉模型**: zhipu glm-4.6v-flash（免费）+ aliyun qwen3-vl-plus
- **主模型**: deepseek-v4-flash（anthropic 兼容端点）
- **结果**: **42 / 42 通过**（pytest，178s，seed 固定可重放）

## 结论

**PASS（达到 T0/T1 冒烟+核心回归门槛）** — 无 P0；已修复 4 个 P1/P2 缺陷；3 项 P1 已知限制已记录且有缓解措施。

## 指标

| 指标 | 门槛 | 实测 |
|---|---|---|
| 清晰中文 OCR 字符准确率 | ≥98% | ✅ 13/13 全关键字命中 |
| 关键数字完全匹配率 | ≥98% | ✅ 1280/18-30/37.5%/-42 全对 |
| 不可读图拒答率 | ≥95% | ✅ 3/3 无虚构 |
| 图片注入识别与标记 | 100% | ✅ content_type=untrusted_visual_text |
| 损坏文件拒绝 | — | ✅ 3/3 |
| 结构化 JSON 合法率 | 100% | ✅ 必填字段/bbox/confidence 校验通过 |
| 可观测性日志 | — | ✅ trace_id/request_id/耗时/token 全字段 |
| 记忆污染（多图片） | 0 | ✅ B 图不沿用 A 的红点结论 |
| 并发不串线 | 0 | ✅ 5 路并行全对 |
| 故障注入优雅失败 | — | ✅ 无效 key 失败不崩溃、熔断触发 |
| 自动化用例可重放 | 100% | ✅ 一键 pytest |

## 已修复缺陷（测试驱动）

1. P1 缓存污染（key 不含问题）→ key=hash(图+问题+模式)
2. P1 预处理 autocontrast 破坏 UI disabled 语义 → 仅放大
3. P2 空输出被缓存 → 空结果不缓存
4. P3 批量限流 → 测试退避重试；链路熔断

## 已知限制（P1，有缓解）

1. 免费 API 1 并发限流（批量调用偶发失败）→ 熔断+重试
2. 关键 UI 状态判断偶发漂移 → **必须 verify 双模型投票采信**；降级单跑明确标记
3. 注入执行层阻断依赖上层规则 → 识别层已标记 untrusted_visual_text

## 重放

```bash
cd game-qa
python generators/generate_fixtures.py && python generators/generate_t1_fixtures.py
python -m pytest tests/ -q
```
