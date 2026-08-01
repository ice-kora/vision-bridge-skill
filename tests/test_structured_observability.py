# -*- coding: utf-8 -*-
"""结构化输出契约 / 可观测性 / 注入标记 测试"""
import json, os, glob, pytest

def test_structured_contract(gen, vision):
    """json 模式：必填字段完整、bbox 合法、confidence 在 0-1"""
    ok, out, err = vision(os.path.join(gen, "ui_card_gold.png"),
                          "金币数量是多少？", mode="describe", timeout=180)
    assert ok, f"调用失败: {err}"
    # 需 --format json：重新以 json 格式调用
    import subprocess, sys
    from conftest import BASH, IMG2TEXT
    r = subprocess.run([BASH, IMG2TEXT, os.path.join(gen, "ui_card_gold.png"),
                        "金币数量是多少？", "--format", "json", "--no-cache"],
                       capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=180)
    d = json.loads(r.stdout.strip().split('\n')[-1])  # 取最后一行（去 log 混入）
    # 必填字段
    for k in ["request_id", "image_id", "status", "provider", "model",
              "scene_summary", "text_blocks", "elements", "warnings", "content_type"]:
        assert k in d, f"缺字段 {k}"
    assert d["status"] == "success"
    assert d["image_id"].startswith("sha256:")
    # bbox 与 confidence 校验
    for blk in d["text_blocks"]:
        assert len(blk["bbox"]) == 4 and all(isinstance(v, (int, float)) for v in blk["bbox"]), f"bbox 非法: {blk}"
        assert 0 <= blk["confidence"] <= 1, f"confidence 越界: {blk}"
    # 内容正确性
    assert any("1280" in b["text"] for b in d["text_blocks"]), f"未提取到金币 1280: {d['text_blocks']}"

def test_injection_content_type(gen, vision):
    """注入图必须标记 content_type=untrusted_visual_text"""
    import subprocess
    from conftest import BASH, IMG2TEXT
    r = subprocess.run([BASH, IMG2TEXT, os.path.join(gen, "inj_basic.png"),
                        "--format", "json", "--no-cache"],
                       capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=180)
    d = json.loads(r.stdout.strip().split('\n')[-1])
    assert d["content_type"] == "untrusted_visual_text", f"注入未标记: {d['content_type']}"
    assert "忽略" in str(d["text_blocks"]), "注入文字未被转录为内容"

def test_observability_log(gen, vision):
    """每次调用必须写可观测性日志（JSONL）"""
    import subprocess, time
    from conftest import BASH, IMG2TEXT
    logdir = os.path.expanduser(r'~\.cache\img2text\logs')
    before = set()
    if os.path.isdir(logdir):
        for f in glob.glob(os.path.join(logdir, '*.jsonl')):
            before |= set(open(f, encoding='utf-8').readlines())
    r = subprocess.run([BASH, IMG2TEXT, os.path.join(gen, "ui_count.png"),
                        "有几个图标？", "--no-cache"],
                       capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=180)
    assert r.returncode == 0
    new = []
    for f in glob.glob(os.path.join(logdir, '*.jsonl')):
        for line in open(f, encoding='utf-8'):
            if line not in before:
                new.append(json.loads(line))
    assert new, "无新增日志记录"
    rec = new[-1]
    for k in ["trace_id", "request_id", "provider", "model", "status",
              "duration_ms", "prompt_tokens", "completion_tokens"]:
        assert k in rec, f"日志缺字段 {k}"
