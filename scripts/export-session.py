"""把 pi 的会话 JSONL 导出为可读的 Markdown 对话记录。"""
import json, sys, os, datetime

sys.stdout.reconfigure(encoding='utf-8')

SF = r"C:/Users/citie/.pi/agent/sessions/--C--Users-citie--/2026-10-04T13-27-00-203Z_01a10718-ad6a-75df-9dc9-b2c4d178f03f.jsonl"
OUT = r"C:/Users/citie/xaga-kvm/conversation.md"
TOOL_LIMIT = 2500          # 单个工具输出最多保留多少字符
THINK = True               # 是否包含思考过程（折叠）

lines = []
for line in open(SF, encoding='utf-8'):
    line = line.strip()
    if line:
        try:
            lines.append(json.loads(line))
        except Exception:
            pass


def ts(msg):
    t = msg.get('timestamp')
    try:
        return datetime.datetime.fromtimestamp(int(t) / 1000).strftime('%Y-%m-%d %H:%M:%S')
    except Exception:
        return ''


def get_text(content):
    """把 content 归一化成 (text, extras) —— extras 是工具调用等结构化项"""
    if isinstance(content, str):
        return content, []
    if not isinstance(content, list):
        return str(content), []
    texts, extras = [], []
    for p in content:
        if not isinstance(p, dict):
            texts.append(str(p)); continue
        pt = p.get('type')
        if pt == 'text':
            texts.append(p.get('text', ''))
        elif pt in ('thinking', 'reasoning'):
            extras.append(('think', p.get('thinking') or p.get('text') or ''))
        elif pt in ('toolCall', 'tool_use', 'tool-call', 'tool_call'):
            nm = p.get('toolName') or p.get('name') or '?'
            args = p.get('args') or p.get('input') or {}
            extras.append(('call', (nm, json.dumps(args, ensure_ascii=False, indent=2))))
        else:
            # 未知类型，尽量保留
            s = json.dumps(p, ensure_ascii=False)
            if len(s) < 400:
                extras.append(('other', s))
    return '\n\n'.join(t for t in texts if t.strip()), extras


def trunc(s, n=TOOL_LIMIT):
    s = s.rstrip()
    if len(s) <= n:
        return s
    head = int(n * 0.7); tail = int(n * 0.25)
    return s[:head] + '\n\n...（中略 %d 字符）...\n\n' % (len(s) - head - tail) + s[-tail:]


out = []
w = out.append

n_user = n_asst = n_tool = 0
first_ts = last_ts = ''

w('# Windows 11 ARM64 on Redmi Note 11T Pro+ (MT6895) — 完整对话记录')
w('')
w('> 由 pi 会话日志导出。工具输出已截断（每条最多 %d 字符）以保持可读。' % TOOL_LIMIT)
w('')
w('**会话 ID**: `01a10718-ad6a-75df-9dc9-b2c4d178f03f`  ')
w('**设备**: Redmi Note 11T Pro+ (xagapro / 22041216UC / MT6895)  ')
w('**主线分支**: `MT6895-Mainline/linux` @ `7.2-mt6895-xiaomi-xaga`')
w('')
w('---')
w('')

for j in lines:
    if j.get('type') != 'message':
        continue
    m = j.get('message') or {}
    role = m.get('role')
    t = ts(m)
    if t:
        if not first_ts:
            first_ts = t
        last_ts = t

    if role == 'system':
        txt, _ = get_text(m.get('content'))
        if txt.strip():
            w('<details><summary>⚙️ 系统上下文 (%s)</summary>' % t)
            w('')
            w('```')
            w(trunc(txt, 4000))
            w('```')
            w('')
            w('</details>')
            w('')

    elif role == 'user':
        txt, extras = get_text(m.get('content'))
        if not txt.strip() and not extras:
            continue
        n_user += 1
        w('## 👤 用户 · %s' % t)
        w('')
        w(txt.strip())
        w('')
        for kind, val in extras:
            if kind == 'call':
                nm, a = val
                w('<details><summary>🔧 %s</summary>' % nm)
                w('')
                w('```json')
                w(trunc(a, 1500))
                w('```')
                w('')
                w('</details>')
                w('')

    elif role == 'assistant':
        txt, extras = get_text(m.get('content'))
        if not txt.strip() and not extras:
            continue
        n_asst += 1
        w('## 🤖 助手 · %s' % t)
        w('')
        if txt.strip():
            w(txt.strip())
            w('')
        for kind, val in extras:
            if kind == 'think' and THINK and val.strip():
                w('<details><summary>💭 思考</summary>')
                w('')
                w(val.strip())
                w('')
                w('</details>')
                w('')
            elif kind == 'call':
                nm, a = val
                w('<details><summary>🔧 调用工具 %s</summary>' % nm)
                w('')
                w('```json')
                w(trunc(a, 2000))
                w('```')
                w('')
                w('</details>')
                w('')

    elif role == 'toolResult':
        n_tool += 1
        nm = m.get('toolName') or '?'
        err = ' ❌ 出错' if m.get('isError') else ''
        txt, _ = get_text(m.get('content'))
        w('<details><summary>📤 %s 返回%s · %s</summary>' % (nm, err, t))
        w('')
        w('```')
        w(trunc(txt))
        w('```')
        w('')
        w('</details>')
        w('')

body = '\n'.join(out)

# 在开头插入统计
stats = []
stats.append('**时间跨度**: %s ~ %s  ' % (first_ts, last_ts))
stats.append('**消息数**: 用户 %d · 助手 %d · 工具返回 %d' % (n_user, n_asst, n_tool))
stats.append('')
stats.append('---')
stats.append('')
idx = body.find('\n---\n')
final = body[:idx] + '\n' + '\n'.join(stats) + body[idx + len('\n---\n'):]

open(OUT, 'w', encoding='utf-8').write(final)
print('已写出: %s' % OUT)
print('  用户 %d · 助手 %d · 工具返回 %d' % (n_user, n_asst, n_tool))
print('  大小: %.2f MB' % (os.path.getsize(OUT) / 1048576))
print('  时间跨度: %s ~ %s' % (first_ts, last_ts))
