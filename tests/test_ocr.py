# -*- coding: utf-8 -*-
"""OCR 层测试：与 ground truth 比对（关键数字/文字匹配）"""
import os, re, pytest

OCR_CASES = [
    # (fixture, 必含关键字, 必不含, 说明)
    ("ocr_cn_simple.png", ["山河为聘"], [], "简体中文"),
    ("ocr_cn_traditional.png", ["山河"], [], "繁体中文（允许繁简差异）"),
    ("ocr_en_mixed.png", ["DeepSeek", "V4"], [], "英文"),
    ("ocr_num_key.png", ["1280", "18/30", "37.5"], [], "关键数字(1280 vs 1230, 18/30 vs 18/80)"),
    ("ocr_num_like.png", ["1", "0", "5", "8"], [], "形近字符 1/I 0/O 5/S 8/B（至少识别为数字）"),
    ("ocr_symbols.png", ["2026-08-02", "12.50"], [], "符号/日期/括号"),
    ("ocr_tiny.png", ["极小", "abc123"], [], "极小字号 12px"),
    ("ocr_lowcontrast.png", ["低对比度"], [], "低对比度"),
    ("ocr_tilt.png", ["倾斜文字"], [], "倾斜 15 度"),
    ("ocr_blur.png", ["模糊文字"], [], "高斯模糊"),
    ("ocr_noise.png", ["噪点文字"], [], "椒盐噪声"),
    ("ocr_mixed.png", ["12,800", "23.4"], [], "中英数混排"),
    ("ocr_gradient.png", ["渐变背景"], [], "渐变背景"),
]

@pytest.mark.parametrize("fname,keys,not_keys,note", OCR_CASES,
                         ids=[c[0] for c in OCR_CASES])
def test_ocr(gen, vision, fname, keys, not_keys, note):
    ok, out, err = vision(os.path.join(gen, fname), "识别图中所有文字，原样输出", mode="ocr")
    assert ok, f"调用失败: {err}"
    out_n = out.replace(" ", "").replace("\n", "")
    for k in keys:
        assert k.replace(" ", "") in out_n, f"缺少关键字 [{k}]（{note}），输出: {out[:200]}"
    for k in not_keys:
        assert k.replace(" ", "") not in out_n, f"不应包含 [{k}]（{note}），输出: {out[:200]}"

def test_ocr_key_number_exact(gen, vision):
    """关键数字完全匹配：1280（非 1230）、18/30（非 18/80）"""
    ok, out, err = vision(os.path.join(gen, "ocr_num_key.png"),
                          "请只输出金币数量、行动力、百分比、负数这四个值", mode="ocr")
    assert ok, f"调用失败: {err}"
    assert "1280" in out and "1230" not in out, f"金币 1280 识别错误: {out[:200]}"
    assert "18/30" in out, f"行动力 18/30 识别错误: {out[:200]}"
    assert "37.5" in out, f"百分比 37.5% 识别错误: {out[:200]}"
    assert "-42" in out, f"负数 -42 识别错误: {out[:200]}"

def test_ocr_table_cell(gen, vision):
    """表格单元格：第三行第三列 = 2800（第二行第三列 = 1200 用于混淆验证）"""
    ok, out, err = vision(os.path.join(gen, "ui_table.png"),
                          "表格第三行第三列的数值是多少？只回答数字", mode="ocr")
    assert ok, f"调用失败: {err}"
    assert "2800" in out, f"单元格 2800 识别错误: {out[:200]}"
