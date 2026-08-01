# -*- coding: utf-8 -*-
"""T1 夹具：DOM 真值网页 + Playwright 截图 + 多图片差异对 + 真实截图 GT
用法: python generators/generate_t1_fixtures.py
输出: fixtures/webpages/（html+png）、fixtures/generated/（差异图）、ground_truth/webpages/gt.json
"""
import json, os, subprocess, sys
from PIL import Image, ImageDraw

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.join(BASE, 'fixtures', 'webpages')
GEN = os.path.join(BASE, 'fixtures', 'generated')
GTW = os.path.join(BASE, 'ground_truth', 'webpages')
os.makedirs(WEB, exist_ok=True)
os.makedirs(GTW, exist_ok=True)

# ═══════════ 1. DOM 真值网页 ═══════════
# DOM 真值（GT 由 HTML 写死，截图后视觉结果与之对比）
DOM_GT = {
    "title": "库存管理",
    "gold": "1280",
    "energy": "18/30",
    "submit_button": {"label": "提交订单", "state": "disabled"},
    "table": {"row3_col3": "2800"},
    "warning_badge": {"position": "top-right", "count": 1},
    "icons": {"total": 5, "red_dots": 2},
}
html = """<!DOCTYPE html><html><head><meta charset="UTF-8">
<style>
body{background:#262220;color:#fff;font-family:'Microsoft YaHei';margin:0;padding:20px}
h1{color:#ddd6fe;font-size:22px}
.top{display:flex;justify-content:space-between;align-items:center}
.gold{color:#ffd700;font-size:20px}
.badge{position:absolute;top:30px;right:30px;width:18px;height:18px;border-radius:50%;background:#ff3b3b}
button#submit{background:#5a5a5a;color:#aaa;border:2px solid #888;padding:10px 24px;font-size:16px;cursor:not-allowed}
table{border-collapse:collapse;margin-top:15px}
td,th{border:1px solid #888;padding:8px 20px;font-size:16px}
.icons{display:flex;gap:14px;margin-top:20px}
.icon{width:64px;height:64px;border:2px solid #c9a227;border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:20px;position:relative}
.dot{position:absolute;top:-6px;right:-6px;width:16px;height:16px;border-radius:50%;background:#ff3b3b}
</style></head><body>
<div class="top"><h1>库存管理</h1><div class="gold">金币: 1280</div></div>
<div class="badge"></div>
<div>行动力: 18/30</div>
<button id="submit" disabled>提交订单</button>
<table><tr><th>项目</th><th>数量</th><th>单价</th></tr>
<tr><td>服务器</td><td>12</td><td>1200</td></tr>
<tr><td>数据库</td><td>3</td><td>2800</td></tr></table>
<div class="icons"><div class="icon">🔍<span class="dot"></span></div><div class="icon">📦</div><div class="icon">⚙️</div><div class="icon">💰<span class="dot"></span></div><div class="icon">📊</div></div>
</body></html>"""
with open(os.path.join(WEB, 'dom_page.html'), 'w', encoding='utf-8') as f:
    f.write(html)

# Playwright 截图（复用 game 的 node_modules，只读）
shot_js = os.path.join(BASE, 'generators', '_t1_shot.js')
with open(shot_js, 'w', encoding='utf-8') as f:
    f.write("""
const { chromium } = require('D:/code/pyCode/game/node_modules/playwright');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 800, height: 620 } });
  await page.goto('file:///D:/code/pyCode/game-qa/fixtures/webpages/dom_page.html');
  await page.waitForTimeout(600);
  await page.screenshot({ path: 'D:/code/pyCode/game-qa/fixtures/webpages/dom_page.png' });
  await browser.close();
  console.log('shot ok');
})();
""")
r = subprocess.run(['node', shot_js], capture_output=True, text=True, encoding='utf-8', errors='replace')
print("playwright:", (r.stdout or r.stderr).strip()[:100])
os.remove(shot_js)

with open(os.path.join(GTW, 'gt.json'), 'w', encoding='utf-8') as f:
    json.dump({"dom_page.png": {"question": "页面中的提交订单按钮状态、金币数量、表格第三行第三列数值、图标数量与红点数", "ground_truth": DOM_GT}}, f, ensure_ascii=False, indent=2)

# ═══════════ 2. 多图片差异对（A/B 找不同 + 记忆污染） ═══════════
def draw_icons(with_dot):
    img = Image.new('RGB', (500, 160), (40, 36, 32))
    d = ImageDraw.Draw(img)
    for i in range(4):
        x = 30 + i * 115
        d.rounded_rectangle([x, 30, x+85, 130], radius=10, outline=(201,162,39), width=2)
        d.text((x+22, 65), "图标", font=__import__('PIL').ImageFont.truetype(r'C:\Windows\Fonts\msyh.ttc', 18), fill=(255,255,255))
        if with_dot and i == 1:
            d.ellipse([x+65, 18, x+87, 40], fill=(255, 60, 60))
    return img

draw_icons(True).save(os.path.join(GEN, 'diff_a.png'))   # A：第 2 个图标带红点
draw_icons(False).save(os.path.join(GEN, 'diff_b.png'))  # B：无红点

print("T1 fixtures 生成完成")
