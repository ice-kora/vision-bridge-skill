# -*- coding: utf-8 -*-
"""pytest 共享夹具：img2text 调用封装 + GT 加载"""
import json, os, subprocess, sys, pytest

QA = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG2TEXT = os.path.expanduser(r'~\.claude\skills\img2text\scripts\img2text.sh')

# Git Bash 绝对路径（Windows Python subprocess 找不到 /bin/bash）
def _find_bash():
    import shutil
    for cand in [shutil.which('bash'), r'C:\Program Files\Git\bin\bash.exe',
                 r'C:\Program Files\Git\usr\bin\bash.exe',
                 os.path.expanduser(r'~\AppData\Local\Programs\Git\bin\bash.exe')]:
        if cand and os.path.exists(cand):
            return cand
    raise RuntimeError('未找到 Git Bash')
BASH = _find_bash()
FIX = os.path.join(QA, 'fixtures')
GEN = os.path.join(FIX, 'generated')
COR = os.path.join(FIX, 'corrupted')
GT_FILE = os.path.join(QA, 'ground_truth', 'generated', 'gt.json')

@pytest.fixture(scope='session')
def gt():
    with open(GT_FILE, encoding='utf-8') as f:
        return json.load(f)

@pytest.fixture(scope='session')
def gt_by_image(gt):
    return {g['image']: g for g in gt}

def run_vision(image_path, question=None, mode=None, timeout=120, retries=2):
    """调用 img2text（含重试，应对免费 API 限流），返回 (ok, text, stderr)"""
    import time
    cmd = [BASH, IMG2TEXT, image_path]
    if question: cmd.append(question)
    if mode: cmd += ['--mode', mode]
    last_err = ''
    for attempt in range(retries + 1):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8',
                               errors='replace', timeout=timeout)
            out = (r.stdout or '').strip()
            if r.returncode == 0 and out:
                return True, out, r.stderr or ''
            last_err = r.stderr or ''
        except subprocess.TimeoutExpired:
            last_err = 'timeout'
        if attempt < retries:
            time.sleep(3 * (attempt + 1))  # 3s, 6s 退避
    return False, '', last_err

@pytest.fixture
def vision():
    return run_vision

@pytest.fixture
def gen():
    return GEN

@pytest.fixture
def cor():
    return COR
