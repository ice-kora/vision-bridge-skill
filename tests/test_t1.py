# -*- coding: utf-8 -*-
"""T1 扩展：DOM 真值对比 / 多图片差异与记忆污染 / 故障注入 / 并发不串线"""
import json, os, subprocess, time, glob, pytest
from conftest import BASH, IMG2TEXT, QA

WEB = os.path.join(QA, 'fixtures', 'webpages')
GEN = os.path.join(QA, 'fixtures', 'generated')

def run(img, question=None, mode=None, fmt=None, timeout=180, env=None, retries=2):
    cmd = [BASH, IMG2TEXT, img, "--no-cache"]  # 故障注入必须绕过缓存（缓存会命中历史成功结果）
    if question: cmd.append(question)
    if mode: cmd += ['--mode', mode]
    if fmt: cmd += ['--format', fmt]
    last = ('', '', 1)
    for i in range(retries + 1):
        r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8',
                           errors='replace', timeout=timeout, env=env)
        out = r.stdout or ''
        if r.returncode == 0 and out.strip():
            # verify 降级单跑（"仅 X 成功"）结果不可靠（GLM 状态判断有漂移）→ 重试
            if mode == "verify" and "仅" in out:
                last = (out, r.stderr or '', r.returncode)
                time.sleep(4 * (i + 1))
                continue
            return out, r.stderr or '', r.returncode
        last = (out, r.stderr or '', r.returncode)
        time.sleep(3 * (i + 1))
    return last

# ═══════════ 1. DOM 真值对比 ═══════════
def test_dom_gold():
    out, err, rc = run(os.path.join(WEB, 'dom_page.png'), "金币数量是多少？只回答数字")
    assert rc == 0 and "1280" in out, f"DOM 真值金币 1280 不符: {out[:150]}"

def test_dom_button_state():
    """关键状态判断：verify 双模型 + 3 次多数采样（模型状态判断存在偶发漂移，P1 已知缺陷；
    双模型一致/多数一致时采信，单模型结果不可靠）"""
    votes = []
    for _ in range(3):
        out, err, rc = run(os.path.join(WEB, 'dom_page.png'),
                           "“提交订单”按钮是否处于禁用状态？回答是或否",
                           mode="verify", timeout=240, retries=0)
        assert rc == 0, f"调用失败: {err}"
        # 模型语义回答是/否（verify 双模型各输出一行）
        answers = [l.strip() for l in out.split('\n') if l.strip() in ('是', '否')]
        assert answers, f"无是/否答案: {out[:100]}"
        votes.append(all(a == '是' for a in answers))
    assert sum(votes) >= 2, f"按钮状态判断漂移（3 次采样 {votes}）: {out[:150]}"

def test_dom_table_cell():
    out, err, rc = run(os.path.join(WEB, 'dom_page.png'),
                       "表格第三行第三列的数值是多少？只回答数字")
    assert rc == 0 and "2800" in out, f"DOM 真值表格 2800 不符: {out[:150]}"

def test_dom_count():
    out, err, rc = run(os.path.join(WEB, 'dom_page.png'),
                       "页面中有几个图标？其中几个带红色圆点？只回答数字")
    assert rc == 0, f"调用失败: {err}"
    assert "5" in out and "2" in out, f"DOM 真值图标 5/红点 2 不符: {out[:150]}"

# ═══════════ 2. 多图片：找不同与记忆污染 ═══════════
def test_multi_diff_a():
    """A 图第 2 个图标有红点"""
    out, err, rc = run(os.path.join(GEN, 'diff_a.png'),
                       "图中有几个图标？是否有红色圆点？只回答数字和是/否")
    assert rc == 0 and ("是" in out or "有" in out), f"A 图红点未识别: {out[:150]}"

def test_multi_diff_b():
    """B 图无红点（接受"否/没有/不存在/无"等否定表达）"""
    out, err, rc = run(os.path.join(GEN, 'diff_b.png'),
                       "图中有几个图标？是否有红色圆点？只回答数字和是/否")
    neg = ("否" in out or "没有" in out or "不存在" in out or "无" in out)
    assert rc == 0 and neg, f"B 图误报红点: {out[:150]}"

def test_memory_pollution():
    """记忆污染：先问 A（有红点）再问 B（无）—— B 的答案不得沿用 A"""
    out_a, _, _ = run(os.path.join(GEN, 'diff_a.png'), "是否有红色圆点？回答是或否")
    out_b, _, _ = run(os.path.join(GEN, 'diff_b.png'), "是否有红色圆点？回答是或否")
    assert ("是" in out_a or "有" in out_a), f"A 应识别有红点: {out_a[:100]}"
    assert ("否" in out_b or "没有" in out_b or "无" in out_b), f"记忆污染：B 沿用了 A 的红点结论: {out_b[:100]}"

# ═══════════ 3. 故障注入 ═══════════
def test_invalid_key_fails_gracefully():
    """无效 key：调用失败但不崩溃（退出码非 0，有错误信息）"""
    env = dict(os.environ, ALIYUN_API_KEY="invalid-key-for-test",
               IMG2TEXT_CHAIN="aliyun")   # 强制走 aliyun 验证 key 失败路径
    out, err, rc = run(os.path.join(GEN, 'ocr_cn_simple.png'), None, mode="ocr",
                       env=env, retries=1)
    assert rc != 0, f"无效 key 不应成功: {out[:100]}"
    assert "img2text" in err, f"应有错误提示: {err[:100]}"

def test_circuit_breaker_triggers():
    """熔断：连续失败达到阈值后出现熔断标记文件（try/finally 保证清理，避免污染其他测试）"""
    cache = os.path.expanduser(r'~\.cache\img2text')
    circ = os.path.join(cache, 'circuit-aliyun')
    count = os.path.join(cache, 'count-aliyun')
    try:
        for f in (circ, count):
            if os.path.exists(f): os.remove(f)
        env = dict(os.environ, ALIYUN_API_KEY="invalid-key-for-circuit",
                   IMG2TEXT_CHAIN="aliyun")   # 强制 aliyun 触发熔断
        for _ in range(5):
            run(os.path.join(GEN, 'ocr_cn_simple.png'), None, mode="ocr", env=env, retries=0)
        assert os.path.exists(circ), "熔断文件未生成（连续 5 次失败应熔断）"
    finally:
        for f in (circ, count):
            if os.path.exists(f): os.remove(f)

# ═══════════ 4. 并发不串线 ═══════════
def test_concurrency_no_cross_talk():
    """5 个并发调用不同图片：各自结果正确（无串线/缓存污染）"""
    import concurrent.futures
    cases = [
        (os.path.join(GEN, 'ocr_cn_simple.png'), "图片中的文字是什么", "山河"),
        (os.path.join(GEN, 'ocr_num_key.png'), "金币数量是多少", "1280"),
        (os.path.join(GEN, 'ui_card_gold.png'), "金币数量是多少？只回答数字", "1280"),
        (os.path.join(GEN, 'ui_count.png'), "有几个图标？只回答数字", "5"),
        (os.path.join(GEN, 'ocr_en_mixed.png'), "文字是什么", "DeepSeek"),
    ]
    def one(c):
        img, q, key = c
        out, err, rc = run(img, q, retries=3)
        return key, key in out
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as ex:
        results = list(ex.map(one, cases))
    fails = [(k, v) for k, v in results if not v]
    assert not fails, f"并发串线/识别失败: {fails}"
