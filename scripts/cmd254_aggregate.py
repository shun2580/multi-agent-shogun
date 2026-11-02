#!/usr/bin/env python3
"""cmd_254 モデル構成変更の前後比較用の集計 (読むだけ・標準出力に Markdown を出す)。

既存のログだけを読み、どこにも書かない(ファイルへ出したければ呼び出し側で > する)。
秘匿値は扱わない: メッセージ本文は task_id の抽出にしか使わず、出力に本文を載せない。

読むもの(すべて読み取り専用):
  logs/audit/<YYYY-MM>/<agent>.jsonl   turn.start / turn.complete(ms) / tool.call
  queue/inbox/*.yaml, queue/archive/inbox_*.yaml   task_assigned / report_received / clear_command
  queue/archive/cmds/cmd_*.yaml, queue/shogun_to_karo.yaml   cmd の名目上の timestamp
  queue/tasks/*.yaml, queue/archive/tasks/*.yaml   bloom_level (残っている分だけ)

使い方:
  python3 scripts/cmd254_aggregate.py --cmds 243-251
  python3 scripts/cmd254_aggregate.py --from 2026-11-03T00:00:00 --to 2026-11-17T00:00:00
  python3 scripts/cmd254_aggregate.py --cmds 255-262 --from ... --to ...   # 両方指定も可
時刻は JST(+09:00) とみなす(監査ログは +09:00、inbox は時刻のみで JST)。
"""
import argparse
import glob
import json
import os
import re
import statistics
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

import yaml

JST = timezone(timedelta(hours=9))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parse_ts(s):
    if isinstance(s, datetime):
        d = s
    else:
        s = str(s).strip().replace(' ', 'T')
        d = datetime.fromisoformat(s)
    if d.tzinfo is None:
        d = d.replace(tzinfo=JST)
    return d.astimezone(JST)


def fmt(d):
    return d.strftime('%m-%d %H:%M:%S') if d else '-'


def fmt_min(sec):
    if sec is None:
        return '-'
    return f'{sec / 60:.1f}分'


def stats_ms(xs):
    if not xs:
        return ('-', '-', '-')
    return (f'{statistics.mean(xs) / 1000:.1f}s', f'{statistics.median(xs) / 1000:.1f}s', f'{max(xs) / 1000:.0f}s')


def cmd_num(cid):
    m = re.search(r'(\d+)', str(cid or ''))
    return int(m.group(1)) if m else None


def parse_cmd_range(s):
    out = set()
    for part in s.split(','):
        part = part.strip()
        if '-' in part:
            a, b = part.split('-', 1)
            out.update(range(int(a), int(b) + 1))
        elif part:
            out.add(int(part))
    return out


def union_ms(intervals):
    """[(start_dt, end_dt)] の和集合の長さ(秒)。同時ターンの二重計上を避ける。"""
    if not intervals:
        return 0.0
    iv = sorted(intervals)
    total = 0.0
    cs, ce = iv[0]
    for s, e in iv[1:]:
        if s <= ce:
            ce = max(ce, e)
        else:
            total += (ce - cs).total_seconds()
            cs, ce = s, e
    total += (ce - cs).total_seconds()
    return total


def load_cmd_timestamps(root):
    res = {}
    for f in glob.glob(os.path.join(root, 'queue/archive/cmds/cmd_*.yaml')):
        try:
            for c in (yaml.safe_load(open(f, encoding='utf-8')) or {}).get('commands', []) or []:
                res[cmd_num(c.get('id'))] = (parse_ts(c['timestamp']), c.get('project'), 'archive/cmds')
        except Exception as e:  # noqa: BLE001
            print(f'[warn] {f}: {e}', file=sys.stderr)
    f = os.path.join(root, 'queue/shogun_to_karo.yaml')
    try:
        d = yaml.safe_load(open(f, encoding='utf-8')) or {}
        for c in d.get('commands', []) or []:
            n = cmd_num(c.get('id'))
            if n not in res and c.get('timestamp'):
                res[n] = (parse_ts(c['timestamp']), c.get('project'), 'shogun_to_karo.yaml')
    except Exception as e:  # noqa: BLE001
        print(f'[warn] {f}: {e}', file=sys.stderr)
    return res


def load_inbox(root):
    seen = {}
    files = glob.glob(os.path.join(root, 'queue/inbox/*.yaml')) + glob.glob(os.path.join(root, 'queue/archive/inbox_*.yaml'))
    meta = []
    for f in files:
        try:
            d = yaml.safe_load(open(f, encoding='utf-8')) or {}
        except Exception as e:  # noqa: BLE001
            print(f'[warn] {f}: {e}', file=sys.stderr)
            continue
        msgs = d.get('messages', []) or []
        ts = [parse_ts(m['timestamp']) for m in msgs if m.get('timestamp')]
        meta.append((os.path.basename(f), len(msgs), min(ts) if ts else None, max(ts) if ts else None))
        base = os.path.basename(f)
        owner = re.sub(r'^inbox_', '', base).replace('.yaml', '')
        owner = re.sub(r'_\d{8,}$', '', owner)
        for m in msgs:
            if not m.get('id') or not m.get('timestamp'):
                continue
            m = dict(m)
            m['_ts'] = parse_ts(m['timestamp'])
            m['_owner'] = owner  # この message が入っていた inbox の持ち主(= 宛先)
            seen[m['id']] = m
    return seen, meta


def load_audit(root, w0, w1):
    per = defaultdict(lambda: {'starts': {}, 'completes': [], 'tools': 0, 'files': set()})
    fmeta = []
    for f in sorted(glob.glob(os.path.join(root, 'logs/audit/*/*.jsonl'))):
        n_all = n_in = 0
        first = last = None
        for line in open(f, encoding='utf-8'):
            line = line.strip()
            if not line:
                continue
            n_all += 1
            try:
                d = json.loads(line)
            except ValueError:
                continue
            t = parse_ts(d['ts'])
            first = t if first is None or t < first else first
            last = t if last is None or t > last else last
            if w0 and t < w0 or w1 and t > w1:
                continue
            n_in += 1
            a = d.get('agent', '_missing')
            p = per[a]
            p['files'].add(os.path.relpath(f, root))
            ev = d.get('event')
            if ev == 'turn.start':
                p['starts'][d.get('turn')] = t
            elif ev == 'turn.complete':
                p['completes'].append((t, d.get('ms'), d.get('turn'), d.get('aborted'), d.get('reason')))
            elif ev == 'tool.call':
                p['tools'] += 1
        fmeta.append((os.path.relpath(f, root), n_all, n_in, first, last))
    return per, fmeta


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--cmds', help='対象 cmd 番号 例 243-251 (省略時は --from/--to に入る timestamp の cmd)')
    ap.add_argument('--from', dest='w0', help='対象期間の開始 ISO (省略時: 対象 cmd の最初の task_assigned)')
    ap.add_argument('--to', dest='w1', help='対象期間の終了 ISO (省略時: 対象 cmd の最後の報告)')
    ap.add_argument('--root', default=ROOT)
    ap.add_argument('--title', default='cmd_254 集計')
    args = ap.parse_args()
    root = args.root

    cmdts = load_cmd_timestamps(root)
    inbox, inbox_meta = load_inbox(root)
    w0 = parse_ts(args.w0) if args.w0 else None
    w1 = parse_ts(args.w1) if args.w1 else None

    if args.cmds:
        want = parse_cmd_range(args.cmds)
    elif w0 and w1:
        want = {n for n, (t, _, _) in cmdts.items() if w0 <= t <= w1}
    else:
        ap.error('--cmds か、--from と --to の両方が要る')

    # ---- inbox から cmd / task 単位の事実を作る ----
    assigns = []  # karo -> ashigaru/gunshi の task_assigned
    reports = []  # ashigaru -> gunshi / gunshi -> karo の report_received
    clears = []
    for m in inbox.values():
        n = cmd_num(m.get('cmd_id'))
        if m.get('type') == 'task_assigned':
            assigns.append(m)
        elif m.get('type') == 'report_received':
            reports.append(m)
        elif m.get('type') == 'clear_command':
            clears.append(m)
    assigns.sort(key=lambda m: m['_ts'])
    reports.sort(key=lambda m: m['_ts'])

    # 割当 → 同じ宛先の次の報告 を対にする(報告 message の task_id は親名に切られるため、
    # task_id ではなく『同じ足軽の、割当後に最初に来た報告』で対にする。間に別の割当が入れば対にしない)
    by_agent_assign = defaultdict(list)
    for m in assigns:
        by_agent_assign[m['_owner']].append(m)
    by_agent_report = defaultdict(list)
    for m in reports:
        by_agent_report[m.get('from')].append(m)

    tasks = []  # dict(cmd, task_id, agent, t_assign, t_report or None)
    for ag, lst in by_agent_assign.items():
        rep = by_agent_report.get(ag, [])
        for i, a in enumerate(lst):
            nxt_assign = lst[i + 1]['_ts'] if i + 1 < len(lst) else None
            r = next((x for x in rep if x['_ts'] > a['_ts']), None)
            if r and nxt_assign and r['_ts'] > nxt_assign:
                r = None
            tasks.append({'cmd': cmd_num(a.get('cmd_id')), 'task_id': a.get('task_id'), 'agent': ag,
                          't_assign': a['_ts'], 't_report': r['_ts'] if r else None})
    tasks = [t for t in tasks if t['cmd'] in want]

    # 期間の既定値
    if not w0:
        w0 = min([t['t_assign'] for t in tasks] or [datetime.now(JST)])
    if not w1:
        w1 = max([t['t_report'] or t['t_assign'] for t in tasks] or [datetime.now(JST)])
    span_s = (w1 - w0).total_seconds()

    out = []
    P = out.append
    P(f'# {args.title}')
    P('')
    P(f'- 対象 cmd: {sorted(want)}')
    P(f'- 対象期間: {w0.isoformat()} 〜 {w1.isoformat()} (壁時計 {span_s / 3600:.1f} 時間)')
    P(f'- 生成: {datetime.now(JST).isoformat(timespec="seconds")} (scripts/cmd254_aggregate.py・読み取りのみ)')
    P('')

    # ---- 0. データ範囲 ----
    audit, ameta = load_audit(root, w0, w1)
    P('## 0. 集計の元にしたログの範囲')
    P('')
    P('### 0.1 監査ログ (logs/audit)')
    P('')
    P('| ファイル | 総行数 | 期間内の行数 | ファイル全体の先頭 | ファイル全体の末尾 |')
    P('|---|---:|---:|---|---|')
    for rel, n_all, n_in, first, last in ameta:
        if n_in:
            P(f'| {rel} | {n_all} | {n_in} | {first.strftime("%F %T")} | {last.strftime("%F %T")} |')
    P('')
    P('### 0.2 inbox 系 (queue/inbox と queue/archive/inbox_*)')
    P('')
    P('| ファイル | 件数 | 先頭の時刻 | 末尾の時刻 |')
    P('|---|---:|---|---|')
    for name, n, a, b in sorted(inbox_meta, key=lambda x: (x[2] or datetime.min.replace(tzinfo=JST))):
        if b and b >= w0 and (a is None or a <= w1):
            P(f'| {name} | {n} | {a.strftime("%F %T") if a else "-"} | {b.strftime("%F %T") if b else "-"} |')
    P('')
    P('※ inbox は slim_yaml が read:true を archive へ移すため、家老宛て(karo)の archive は存在せず、'
      '家老の inbox は直近分しか残らない。task YAML は上書きされ履歴を持たない。取れない項目は各節に明記する。')
    P('')

    # ---- 1. エージェント別 ----
    P('## 1. エージェントごとのターン')
    P('')
    P('稼働率 = (ターン実行中の時間の和集合 ÷ 対象期間の壁時計)。ターンの区間は turn.complete の時刻から ms を引いて作る。'
      '同時に走るターンは和集合で一度だけ数える。')
    P('')
    P('| agent | ターン数(完了) | 平均 | 中央値 | 最大 | 中断(aborted) | 未完了start | tool.call | 稼働率 |')
    P('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    order = ['shogun', 'karo', 'gunshi'] + [f'ashigaru{i}' for i in range(1, 9)]
    names = [a for a in order if a in audit] + sorted(a for a in audit if a not in order)
    for a in names:
        p = audit[a]
        comp = [c for c in p['completes'] if isinstance(c[1], (int, float))]
        ms = [c[1] for c in comp]
        iv = [(c[0] - timedelta(milliseconds=c[1]), c[0]) for c in comp]
        busy = union_ms(iv)
        done_ids = {c[2] for c in p['completes']}
        open_starts = sum(1 for k in p['starts'] if k not in done_ids)
        ab = sum(1 for c in p['completes'] if c[3])
        mean, med, mx = stats_ms(ms)
        P(f'| {a} | {len(p["completes"])} | {mean} | {med} | {mx} | {ab} | {open_starts} | {p["tools"]} | {busy / span_s * 100:.1f}% |')
    P('')
    unk = [a for a in audit if a.startswith('_') or a in ('unknown', '')]
    P(f'- `_unknown` / 不明 agent の行: {"あり " + str(unk) if unk else "この期間には無し"}')
    P('- モデル名: 監査ログの項目は ts/agent/event/turn/tool/ok/ms/aborted/reason/file_path/sub/outcome のみで '
      '**モデル名・effort は記録されない**。席ごとのモデルは config/settings.yaml の履歴でしか分からない(取れない)。')
    P('')

    # ---- 2. cmd ごと ----
    P('## 2. cmd ごとの所要')
    P('')
    P('「下命」= その cmd の最初の task_assigned(karo→足軽/軍師)。「完了」= その cmd に属する割当の後に来た最後の報告。'
      'cmd 本体の timestamp は名目値(例: cmd_243 は最初の割当 21:27 より後の 21:45 と記され、cmd_246/247 は割当より後)ゆえ参考表示に留める。')
    P('')
    P('| cmd | project | 名目timestamp | 最初の割当 | 最後の報告 | 下命→完了 | 割当(延べ) | 異なる task_id | 報告と対にできた割当 | 軍師宛の割当 | clear_command |')
    P('|---|---|---|---|---|---:|---:|---:|---:|---:|---:|')
    cmd_rows = []
    for n in sorted(want):
        ts = [t for t in tasks if t['cmd'] == n]
        first = min([t['t_assign'] for t in ts], default=None)
        reps = [t['t_report'] for t in ts if t['t_report']]
        last = max(reps, default=None)
        dur = (last - first).total_seconds() if first and last else None
        n_g = sum(1 for t in ts if t['agent'] == 'gunshi')
        n_cl = sum(1 for m in clears if cmd_num(m.get('cmd_id')) == n)
        nominal = cmdts.get(n, (None,))[0]
        distinct = len({t['task_id'] for t in ts})
        paired = sum(1 for t in ts if t['t_report'])
        cmd_rows.append((n, dur))
        P(f'| cmd_{n} | {cmdts.get(n, (None, "?"))[1] or "?"} | {fmt(nominal)} | {fmt(first)} | {fmt(last)} | {fmt_min(dur)} | {len(ts)} | {distinct} | {paired} | {n_g} | {n_cl} |')
    P('')
    gn = [t for t in tasks if t['agent'] == 'gunshi']
    P(f'- 軍師 QC の往復回数: 軍師宛の task_assigned が inbox に残るのは {len(gn)} 件(' +
      (', '.join(sorted({f"cmd_{t['cmd']}" for t in gn})) or 'なし') +
      ')。家老の inbox は archive が無く直近分のみ、軍師の report YAML も上書きで履歴が無いため、'
      '**差し戻し→再審査の往復回数は期間全体では取れない**。残っている範囲の clear_command(redo の合図。ただし文脈リセットでも使う)'
      '件数を上表に併記した。')
    P('- 「報告と対にできた割当」が「割当(延べ)」より少ない cmd は、報告 message が archive 側に残っていない(または割当後に別の割当が入った)。'
      '下命→完了はその分、短く出る側に偏る。')
    P('')

    # ---- 3. task ごと ----
    P('## 3. task ごとの bloom_level と所要時間')
    P('')
    bl = Counter()
    bl_files = []
    for f in glob.glob(os.path.join(root, 'queue/tasks/*.yaml')) + glob.glob(os.path.join(root, 'queue/archive/tasks/*.yaml')):
        try:
            d = (yaml.safe_load(open(f, encoding='utf-8')) or {}).get('task') or {}
        except Exception:  # noqa: BLE001
            continue
        if not d.get('bloom_level') or not d.get('timestamp'):
            continue
        t = parse_ts(d['timestamp'])
        if w0 <= t <= w1 and cmd_num(d.get('parent_cmd')) in want:
            bl[d['bloom_level']] += 1
            bl_files.append(os.path.relpath(f, root))
    if bl:
        P(f'- 期間内の task YAML に残る bloom_level: {dict(sorted(bl.items()))} (元: {", ".join(bl_files)})。'
          '残っているのは各席の『最後の task』だけで、期間内の割当の大半は上書きで失われている。分布の母集団には足りない(取れない)。')
    else:
        P('- 期間内の task YAML に残る bloom_level: **0 件**。queue/tasks/*.yaml は次の割当で上書きされ、'
          'queue/archive/tasks/ にも直近の履歴が無い。inbox の task_assigned message は bloom_level を持たない。'
          'よって **bloom_level の分布と L1〜L3 の所要時間は、この期間では取れない**(推測で埋めない)。')
    P('')
    P('### 3.1 割当→報告の所要(bloom_level で分けられないため、足軽別・全体)')
    P('')
    P('下命から完了までの時間ではなく『割当 message から、同じ足軽の次の報告 message まで』。足軽が前の仕事中に割当が入った場合の待ちを含む。')
    P('')
    P('| agent | 対にできた件数 | 中央値 | 平均 | 最大 |')
    P('|---|---:|---:|---:|---:|')
    allx = []
    for ag in sorted({t['agent'] for t in tasks}):
        xs = [(t['t_report'] - t['t_assign']).total_seconds() for t in tasks if t['agent'] == ag and t['t_report']]
        allx += xs
        if xs:
            P(f'| {ag} | {len(xs)} | {fmt_min(statistics.median(xs))} | {fmt_min(statistics.mean(xs))} | {fmt_min(max(xs))} |')
    if allx:
        P(f'| (全体) | {len(allx)} | {fmt_min(statistics.median(allx))} | {fmt_min(statistics.mean(allx))} | {fmt_min(max(allx))} |')
    P('')

    # ---- 4. 待ち ----
    P('## 4. 待ちの内訳')
    P('')
    P('足軽が『報告してから次の割当が来るまで』の空き。これは 軍師の QC + 家老の判断と起票 + 前の工程待ち の合算で、'
      '**相手(家老/軍師/前の工程)別には分けられない**(家老→軍師の QC 依頼と軍師→家老の結果が期間全体では残っていないため)。')
    P('')
    P('| agent | 空きの件数 | 中央値 | 平均 | 最大 | うち60分超の件数 | 空き合計 | 同じ期間の稼働(turn)合計 |')
    P('|---|---:|---:|---:|---:|---:|---:|---:|')
    for ag in sorted({t['agent'] for t in tasks if t['agent'].startswith('ashigaru')}):
        lst = sorted([t for t in assigns if t['_owner'] == ag and w0 <= t['_ts'] <= w1], key=lambda m: m['_ts'])
        rep = sorted([m for m in reports if m.get('from') == ag], key=lambda m: m['_ts'])
        gaps = []
        for a in lst:
            prev = [r for r in rep if r['_ts'] < a['_ts'] and r['_ts'] >= w0]
            if prev:
                g = (a['_ts'] - prev[-1]['_ts']).total_seconds()
                # 前の報告より後に別の割当があった(= 待たずに連続で来た)場合は 0 扱いにせず除外
                if not [x for x in lst if prev[-1]['_ts'] < x['_ts'] < a['_ts']]:
                    gaps.append(g)
        busy = union_ms([(c[0] - timedelta(milliseconds=c[1]), c[0]) for c in audit.get(ag, {'completes': []})['completes']
                         if isinstance(c[1], (int, float))])
        if gaps:
            P(f'| {ag} | {len(gaps)} | {fmt_min(statistics.median(gaps))} | {fmt_min(statistics.mean(gaps))} | {fmt_min(max(gaps))} | {sum(1 for g in gaps if g > 3600)} | {fmt_min(sum(gaps))} | {fmt_min(busy)} |')
    P('')
    P('- 平均は、cmd と cmd の間・夜間など『動かすべき cmd が無かった』空きに引かれる(60分超の列)。比べるなら中央値と60分以内の件数を見よ。')
    P('- 家老・軍師の待ちは、上の稼働率の裏(= 1 − 稼働率)としてしか見えない。**『誰を待っていたか』の相手別内訳は取れない**。')
    P('')
    return '\n'.join(out)


if __name__ == '__main__':
    print(main())
