#!/bin/bash
# ============================================================
# img2text v2 —— 无视觉模型的眼睛（Vision Bridge）
# 通用 · 完善 · 安全 · 可靠 · 快
#
# 用法:
#   img2text.sh <图片路径或URL> ["问题(可选)"]
#   img2text.sh <图片> --mode ocr          # OCR 文字提取（结构化）
#   img2text.sh <图片> --mode ui-review    # UI/UX 审查
#   img2text.sh <图片> --mode verify       # 双模型交叉验证（GLM + Qwen 投票）
#   img2text.sh <图片> --format json       # 结构化输出
#   img2text.sh <图片> --no-cache          # 跳过缓存
#   img2text.sh --providers                # 列出可用 provider 与状态
#
# Provider 选择（环境变量 IMG2TEXT_CHAIN，逗号分隔按序故障转移）:
#   zhipu (默认): GLM-4.6V-Flash 免费 / key: ~/.zhipu_key 或 ZHIPU_API_KEY
#   aliyun      : qwen-vl-ocr 免费额度+按量 / key: ~/.dashscope_key 或 DASHSCOPE_API_KEY
#
# 安全: 魔数校验 · key 不落输出 · 临时文件 trap 清理 · 大小限制
# 可靠: 熔断(5 次失败冷却 60s) · curl 重试 · 无 key 自动跳过
# 快  : SHA256 内容缓存(7 天 TTL) · verify 并行双请求
# ============================================================

set -euo pipefail

# ---------- 常量 ----------
CACHE_DIR="${HOME}/.cache/img2text"
CIRCUIT_FILE="$CACHE_DIR/circuit"
TTL=604800                 # 缓存 7 天
MAX_BYTES=5242880          # 5MB
BREAK_N=5                  # 熔断阈值
BREAK_COOL=60              # 熔断冷却秒
declare -A P_URL; declare -A P_KEY; declare -A P_MODEL; declare -A P_DESC

# ---------- Provider 注册表（纯数据：新增 = 加 3 行） ----------
P_URL[zhipu]="https://open.bigmodel.cn/api/paas/v4/chat/completions"
P_KEY[zhipu]="$HOME/.zhipu_key"
P_MODEL[zhipu]="glm-4.6v-flash"
P_DESC[zhipu]="智谱 GLM-4.6V-Flash（永久免费）"

P_URL[aliyun]="https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
P_KEY[aliyun]="$HOME/.dashscope_key"
P_MODEL[aliyun]="qwen3-vl-plus"
P_DESC[aliyun]="阿里 qwen3-vl-plus（视觉理解，多模态）"

# ---------- 基础工具 ----------
log() { echo "[img2text] $*" >&2; }
LOG_DIR="$CACHE_DIR/logs"
TRACE_ID="$(date +%s)-$RANDOM$RANDOM"   # 每次调用唯一
trace_log() { # 可观测性：每行 JSONL 追加日志（ts/trace/request/图/模型/耗时/错误/token）
  mkdir -p "$LOG_DIR"
  printf '%s\n' "$1" >> "$LOG_DIR/vision-$(date +%Y%m%d).jsonl"
}
img_size() { # 图片宽高（本地文件；URL 或失败返回 0x0）
  local f="$1"
  [[ "$f" =~ ^https?:// ]] && { echo "0x0"; return; }
  python - "$(cygpath -w "$f" 2>/dev/null || echo "$f")" <<'PYEOF' 2>/dev/null || echo "0x0"
import sys
from PIL import Image
print(f"{Image.open(sys.argv[1]).size[0]}x{Image.open(sys.argv[1]).size[1]}")
PYEOF
}

# ---------- 参数解析 ----------
IMG=""; QUESTION=""; MODE="auto"; FORMAT="text"; USE_CACHE=1
CHAIN="${IMG2TEXT_CHAIN:-zhipu}"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    --format) FORMAT="$2"; shift 2;;
    --no-cache) USE_CACHE=0; shift;;
    --providers) for p in "${!P_DESC[@]}"; do
                    k="${P_KEY[$p]}"; st="❌ 未配置 key"
                    [ -f "$k" ] && st="✅ 已配置"
                    echo "$p | ${P_MODEL[$p]} | ${P_DESC[$p]} | $st"
                  done | sort; exit 0;;
    -*) echo "未知参数: $1" >&2; exit 2;;
    *) if [ -z "$IMG" ]; then IMG="$1"; else QUESTION="$1"; fi; shift;;
  esac
done
[ -z "$IMG" ] && { echo "用法: img2text.sh <图片路径或URL> [\"问题\"] [--mode describe|ocr|ui-review|verify] [--format text|json] [--no-cache]" >&2; exit 2; }

# verify = 双模型投票（固定 zhipu+aliyun 并行），不使用故障转移链
[ "$MODE" = "verify" ] && CHAIN="${IMG2TEXT_VERIFY_CHAIN:-zhipu,aliyun}"

# json 模式：追加结构化输出指令（视觉层直接产出 bbox/confidence/elements）
if [ "$FORMAT" = "json" ]; then
  QUESTION="$QUESTION 请严格以JSON格式输出（不要输出JSON以外的内容）：{\"scene_summary\":\"场景概述\",\"text_blocks\":[{\"text\":\"识别出的文字\",\"bbox\":[x1,y1,x2,y2],\"confidence\":0.95}],\"elements\":[{\"type\":\"button|icon|input|text|badge\",\"label\":\"元素名\",\"bbox\":[x1,y1,x2,y2],\"state\":\"normal|disabled|active\"}],\"warnings\":[\"发现的问题\"]}。bbox 为图片像素坐标，confidence 为0到1的数字，无法识别时 text 为空字符串。"
fi

# ---------- 图片类型自动分类（程序化特征，零成本） ----------
classify_image() { # 输出: doc | ui | art | unknown
  python - "$(cygpath -w "$1" 2>/dev/null || echo "$1")" <<'PYEOF'
import sys
from PIL import Image
import numpy as np
img = Image.open(sys.argv[1]).convert('RGB')
arr = np.asarray(img, dtype=np.uint8)
lum = arr.mean(axis=2)
white = float((lum > 235).mean())
mx = arr.max(axis=2).astype(int); mn = arr.min(axis=2).astype(int)
sat = float(np.where(mx > 0, (mx-mn)/np.maximum(mx,1), 0).mean())
dx = np.abs(np.diff(lum.astype(int), axis=1)) > 60
dy = np.abs(np.diff(lum.astype(int), axis=0)) > 60
border = float((dx.mean() + dy.mean())/2)
color = float(((sat > 0.25) & (lum > 40)).mean())
# 启发式规则：文档(白底低饱和) / UI(深色高饱和或边框密集) / 自然图(多色低边框)
if white > 0.6 and sat < 0.08:
    print("doc")
elif white < 0.2 and sat > 0.12:
    print("ui")
elif border > 0.02:
    print("ui")
elif color > 0.12 and border < 0.005:
    print("art")
else:
    print("unknown")
PYEOF
}

# ---------- 模式 → 默认问题 ----------
case "$MODE" in
  ocr)       QUESTION="${QUESTION:-识别图中所有文字，包括表格内数据，原样输出，保留换行和格式}" ;;
  ui-review) QUESTION="${QUESTION:-以UI/UX设计师视角严格审查截图：元素对齐、间距一致性、文字截断/重叠、对比度、图标风格统一性、视觉层级，逐条列出位置和问题}" ;;
  verify)    QUESTION="${QUESTION:-请提取这张图片中的关键信息（如果是文字图请完整转录文字和数字）}" ;;
  describe)  QUESTION="${QUESTION:-详细描述这张图，包括整体布局、配色、文字内容、人物/元素细节，以及任何明显的瑕疵或问题（如锯齿、毛边、变形、色差）}" ;;
  auto)  if [[ ! "$IMG" =~ ^https?:// ]]; then
           CLS=$(classify_image "$IMG")
           case "$CLS" in
             doc) QUESTION="${QUESTION:-识别图中所有文字，包括表格内数据，原样输出，保留换行和格式}" ;;
             ui)  QUESTION="${QUESTION:-以UI/UX设计师视角严格审查截图：元素对齐、间距一致性、文字截断/重叠、对比度、图标风格统一性、视觉层级，逐条列出位置和问题}" ;;
             art) QUESTION="${QUESTION:-详细描述这张图，包括整体布局、配色、文字内容、人物/元素细节，以及任何明显的瑕疵或问题}" ;;
             *)   QUESTION="${QUESTION:-判断这张图的类型（UI界面/文档文字/自然图片），UI则审查布局与元素、文档则完整转录文字、自然图则描述内容}" ;;
           esac
           log "自动分类: $CLS → ${QUESTION:0:24}..."
         fi ;;
esac

# ---------- 工具函数 ----------
mk() { mkdir -p "$CACHE_DIR"; }

get_key() {
  local p="$1" f="${P_KEY[$p]}"
  local k="$(eval echo \${${p^^}_API_KEY:-})"
  if [ -z "$k" ] && [ -f "$f" ]; then k="$(cat "$f" | tr -d ' \r\n')"; fi
  echo "$k"
}

is_broken() { # provider 熔断检查
  local p="$1" f="$CIRCUIT_FILE-$p" now=$(date +%s)
  [ -f "$f" ] && [ $((now - $(cat "$f"))) -lt $BREAK_COOL ]
}

break_on() { # 失败计数：连续 N 次 → 熔断
  local p="$1" f="$CACHE_DIR/count-$p" now=$(date +%s) n=0
  [ -f "$f" ] && n=$(cat "$f")
  n=$((n + 1))
  if [ $n -ge $BREAK_N ]; then
    echo "$now" > "$CIRCUIT_FILE-$p"
    rm -f "$f"
    log "⚠ $p 连续失败 ${BREAK_N} 次，熔断 ${BREAK_COOL}s"
  else
    echo "$n" > "$f"
  fi
}
break_ok() { rm -f "$CACHE_DIR/count-$p"; }

magic_check() { # 魔数校验（防伪装文件）
  local f="$1"
  head -c 12 "$f" | od -An -tx1 | tr -d ' \n' | grep -qiE '^(89504e470d0a1a0a|ffd8ff|4749463839|52494646)' \
    || { log "✗ 文件头不是合法图片 (PNG/JPEG/GIF/WebP)，拒绝处理: $f"; exit 2; }
}

preprocess() { # 预处理：仅小图放大 2x（<800px 边）。不做对比度增强——
  # autocontrast 会改变深色 UI 的颜色/对比度，破坏按钮 disabled 状态等视觉语义（P1 实测缺陷）
  local src="$1"
  local out="$CACHE_DIR/pre-$(sha256sum "$src" | cut -c1-12).png"
  # python 需要 Windows 路径（POSIX /c/... 打不开）
  python - "$(cygpath -w "$src" 2>/dev/null || echo "$src")" "$(cygpath -w "$out" 2>/dev/null || echo "$out")" <<'PYEOF'
import sys
from PIL import Image
src, out = sys.argv[1], sys.argv[2]
img = Image.open(src)
w, h = img.size
# 小图放大 2 倍（<800px 边），大图不动（避免 API 体积超限）
if max(w, h) < 800:
    img = img.resize((w*2, h*2), Image.LANCZOS)
img.save(out)
PYEOF
  echo "$out"
}

cache_get() { # 缓存读取：hash 命中 → 输出并退出；未命中正常返回
  local h="$1"
  local f="$CACHE_DIR/$h.txt"
  if [ $USE_CACHE -eq 1 ] && [ -f "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt $TTL ]; then
    cat "$f"
    exit 0
  fi
  return 0
}
cache_put() { local h="$1"; mk; cat > "$CACHE_DIR/$h.txt"; }

call_provider() { # 单个 provider 调用（curl 文件体避免 32KB 限制）
  local p="$1" url="${P_URL[$p]}" model="${P_MODEL[$p]}" key="$2" img_ref="$3" q="$4"
  local body_f b64_f req_id="$TRACE_ID-$p" t0="$EPOCHREALTIME"
  body_f=$(mktemp); b64_f=$(mktemp)
  trap 'rm -f "$body_f" "$b64_f"' RETURN
  if [[ "$img_ref" =~ ^https?:// ]]; then
    printf '%s' "$img_ref" > "$b64_f"
  else
    printf 'data:image/png;base64,%s' "$(base64 -w 0 "$img_ref")" > "$b64_f"
  fi
  python - "$b64_f" "$model" "$q" > "$body_f" <<'PYEOF'
import json, sys
sys.stdout.reconfigure(encoding='utf-8')
b64 = open(sys.argv[1], encoding='utf-8').read().strip()
model, q = sys.argv[2], sys.argv[3]
print(json.dumps({"model": model, "messages": [{"role": "user", "content": [
    {"type": "image_url", "image_url": {"url": b64}},
    {"type": "text", "text": q}]}], "max_tokens": 4096}, ensure_ascii=False))
PYEOF
  local resp_f; resp_f=$(mktemp)
  trap 'rm -f "$body_f" "$b64_f" "$resp_f"' RETURN
  if ! curl -sS --max-time 90 --retry 2 --retry-delay 3 --request POST \
      --url "$url" \
      --header "authorization: Bearer $key" \
      --header 'content-type: application/json' \
      --data @"$body_f" -o "$resp_f" 2>/dev/null; then
    trace_log "{\"ts\":\"$(date -Iseconds)\",\"trace_id\":\"$TRACE_ID\",\"request_id\":\"$req_id\",\"provider\":\"$p\",\"model\":\"$model\",\"status\":\"network_error\",\"duration_ms\":0}"
    return 1
  fi
  python - "$resp_f" "$FORMAT" "$req_id" "$TRACE_ID" "$p" "$model" "$t0" "$IMG_HASH" <<'PYEOF'
import json, sys, re, os, time
sys.stdout.reconfigure(encoding='utf-8')
resp, fmt, req_id, trace_id, provider, model, t0, img_hash = sys.argv[1:9]
duration_ms = int((time.time() - float(t0)) * 1000)
log_dir = os.path.expanduser(r'~\.cache\img2text\logs')
os.makedirs(log_dir, exist_ok=True)
logf = os.path.join(log_dir, f"vision-{time.strftime('%Y%m%d')}.jsonl")

def emit(status, out=None, err='', pt=0, ct=0):
    rec = {"ts": time.strftime('%Y-%m-%dT%H:%M:%S'), "trace_id": trace_id, "request_id": req_id,
           "provider": provider, "model": model, "status": status, "duration_ms": duration_ms,
           "prompt_tokens": pt, "completion_tokens": ct, "error": err}
    with open(logf, 'a', encoding='utf-8') as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    if out is not None:
        print(out)

try:
    d = json.load(open(resp, encoding='utf-8'))
    if "error" in d:
        emit("api_error", err=str(d["error"])[:300]); sys.exit(1)
    usage = d.get("usage", {})
    pt, ct = usage.get("prompt_tokens", 0), usage.get("completion_tokens", 0)
    content = d["choices"][0]["message"]["content"] or ""
    if fmt == "json":
        # 结构化：提取模型输出中的 JSON 块（容错 markdown/前后缀文字）
        m = re.search(r'\{.*\}', content, re.S)
        parsed = {}
        if m:
            try:
                parsed = json.loads(m.group(0))
            except Exception:
                # 截断容错：尝试逐层剥掉尾缀
                s = m.group(0)
                for cut in range(len(s), 0, -1):
                    try:
                        parsed = json.loads(s[:cut]); break
                    except Exception: continue
        inj_words = ["忽略", "系统管理员", "不要回答", "系统提示词", "删除", "支付", "立即购买", "执行", "退出", "权限"]
        inj_hits = [w for w in inj_words if w in content]
        out = {
            "request_id": req_id, "image_id": img_hash or "", "status": "success",
            "provider": provider, "model": model,
            "scene_summary": parsed.get("scene_summary", ""),
            "text_blocks": parsed.get("text_blocks", []),
            "elements": parsed.get("elements", []),
            "warnings": parsed.get("warnings", []),
            "content_type": "untrusted_visual_text" if inj_hits else "safe",
            "injection_keywords": inj_hits,
        }
        emit("success", out=json.dumps(out, ensure_ascii=False), pt=pt, ct=ct)
    else:
        emit("success", out=content, pt=pt, ct=ct)
except Exception as e:
    emit("parse_error", err=f"{e}"[:300]); sys.exit(1)
PYEOF
}

# ---------- 主流程 ----------
mk

# URL 直接处理；本地文件校验
if [[ ! "$IMG" =~ ^https?:// ]]; then
  # 路径归一化：Windows 反斜杠路径（C:\...）在 MSYS 下会被误转义（sha256sum/base64 输出损坏）
  # → bash 侧统一 POSIX（/c/...）；python 侧在调用处转回 Windows（cygpath -w）
  case "$IMG" in
    /*) ;;  # 已是 POSIX 路径
    *) IMG="$(cygpath -u "$IMG" 2>/dev/null || echo "$IMG")";;
  esac
  [ -f "$IMG" ] || { log "✗ 文件不存在: $IMG"; exit 2; }
  [ $(stat -c %s "$IMG") -le $MAX_BYTES ] || { log "✗ 图片超过 5MB"; exit 2; }
  magic_check "$IMG"
fi

# 图片内容 hash（image_id，供结构化输出/日志）
IMG_HASH=""
if [[ ! "$IMG" =~ ^https?:// ]]; then
  IMG_HASH="sha256:$(sha256sum "$IMG" | cut -d' ' -f1)"
fi

# 缓存（本地文件）—— key 必须含问题与模式，否则同图不同问法会命中旧答案（缓存污染）
HASH=""
if [[ ! "$IMG" =~ ^https?:// ]] && [ $USE_CACHE -eq 1 ]; then
  HASH=$(printf '%s|%s|%s' "$(sha256sum "$IMG")" "$QUESTION" "$MODE" | sha256sum | cut -c1-16)
  cache_get "$HASH"
fi

# 预处理（本地文件：放大+对比度）
WORK="$IMG"
if [[ ! "$IMG" =~ ^https?:// ]] && [ $MODE != "verify" ]; then
  PRE=$(preprocess "$IMG" 2>/dev/null) && WORK="$PRE" && trap 'rm -f "$PRE"' EXIT
fi

# Provider 链调用（故障转移）
if [ "$MODE" = "verify" ]; then
  # 双模型并行投票：zhipu + aliyun（谁配了 key 用谁；缺一降级为单跑+注明）
  # 注：不用关联数组 —— bash 5.2 + set -u 下空关联数组 ${#arr[@]} 会误报 unbound
  R_Z=""; R_A=""
  PIDS=""
  for p in ${CHAIN//,/ }; do
    k=$(get_key "$p"); [ -z "$k" ] && continue
    if is_broken "$p"; then log "⏸ $p 熔断中，跳过"; continue; fi
    ( call_provider "$p" "$k" "$WORK" "$QUESTION" > "$CACHE_DIR/v-$p.txt" 2>/dev/null; \
      echo "$?" > "$CACHE_DIR/vcode-$p.txt" ) &
    PIDS="$PIDS $!"
  done
  [ -z "$PIDS" ] && { log "✗ 无可用 provider（检查 ~/.zhipu_key / ~/.dashscope_key）"; exit 2; }
  for p in $PIDS; do wait "$p" 2>/dev/null || true; done
  for p in ${CHAIN//,/ }; do
    [ -f "$CACHE_DIR/v-$p.txt" ] || continue
    [ "$(cat "$CACHE_DIR/vcode-$p.txt" 2>/dev/null)" = "0" ] || continue
    case "$p" in
      zhipu)  R_Z="$(cat "$CACHE_DIR/v-$p.txt")";;
      aliyun) R_A="$(cat "$CACHE_DIR/v-$p.txt")";;
    esac
    rm -f "$CACHE_DIR/v-$p.txt" "$CACHE_DIR/vcode-$p.txt"
  done
  N=0; [ -n "$R_Z" ] && N=$((N+1)); [ -n "$R_A" ] && N=$((N+1))
  [ $N -eq 0 ] && { log "✗ verify 全部失败"; exit 1; }
  if [ $N -ge 2 ]; then
    log "✓ 双模型结果均成功，已采信（可人工比对差异）"
    [ -n "$R_Z" ] && { echo "───── [zhipu] ${P_MODEL[zhipu]} ─────"; echo "$R_Z"; }
    [ -n "$R_A" ] && { echo "───── [aliyun] ${P_MODEL[aliyun]} ─────"; echo "$R_A"; }
  else
    if [ -n "$R_Z" ]; then log "⚠ 仅 ${P_MODEL[zhipu]} 成功（另一 provider 不可用），结果仅供参考"; echo "$R_Z"
    else log "⚠ 仅 ${P_MODEL[aliyun]} 成功（另一 provider 不可用），结果仅供参考"; echo "$R_A"; fi
  fi
else
  LAST_ERR=""
  for p in ${CHAIN//,/ }; do
    k=$(get_key "$p"); [ -z "$k" ] && { log "ℹ $p 未配置 key，跳过"; continue; }
    if is_broken "$p"; then log "⏸ $p 熔断中，跳过"; continue; fi
    if OUT=$(call_provider "$p" "$k" "$WORK" "$QUESTION" 2>"$CACHE_DIR/err.txt"); then
      if [ -z "$OUT" ]; then
        log "✗ $p 返回空结果（不缓存，计入失败）"
        break_on "$p"
        continue
      fi
      break_ok "$p"
      [ -n "$HASH" ] && { echo "$OUT" | cache_put "$HASH"; }
      echo "$OUT"
      exit 0
    else
      log "✗ $p 调用失败: $(head -c 120 "$CACHE_DIR/err.txt")"
      break_on "$p"
      LAST_ERR="all providers failed"
    fi
  done
  log "✗ $LAST_ERR"
  exit 1
fi
