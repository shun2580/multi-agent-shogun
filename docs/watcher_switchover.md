# inbox_watcher 起動経路の一本化・切替手順(cmd_198 工程6 / Q53)

## 背景

これまで `shutsujin_departure.sh` は起動のたびに、①既存watcherへの
`pkill` → ②将軍・家老・足軽N・軍師の計10体分の `inbox_watcher.sh` を
直接 `nohup` 起動、という処理を自前で行っていた。これとは別に
`watcher_supervisor.sh` も5秒周期の `start_all_watchers` ループで同じ
10体を冪等起動しており、起動元が二重に存在していた(TOCTOUの温床)。

本是正(cmd_198工程6)により、`shutsujin_departure.sh` からは直接launch
ブロック(pkill + 10体分nohup)を削除し、`watcher_supervisor.sh` を
**唯一の起動元**とした。これにより将来の起動では二重起動の懸念自体が
構造的に解消される。

🔴 flockは追加していない。裁定書(`~/fable_ruling_20260916_q53q59.md`
Q53節)が「launcherが一つになればTOCTOUの相手が消えるため、既存の
pgrep冪等(`start_watcher_if_missing()`)で足りる」と明示的に判断した
ため。

## 本是正では行っていないこと

🔴 D006(kill/pkill/tmux kill-*絶対禁止)により、本タスクでは**既存の
稼働中プロセスの停止を一切行っていない**。そのため、本是正が
`main`ブランチへ反映された後も、**過去の起動(pkillベースの旧
launcherが生成した10プロセス)がまだ生きていれば、それはそのまま
動き続ける**。以下は殿が手元で行う必要がある作業の説明であり、
本カード(shutsujin_departure.sh / watcher_supervisor.sh)側の対応は
完了している。

## 現在稼働中の系統の確認方法

以下のコマンドで、稼働中の `inbox_watcher.sh` プロセスを一覧できる。

```bash
pgrep -af "scripts/inbox_watcher.sh"
```

- 本是正の反映**前**に起動されたセッションが稼働中の場合、
  `shutsujin_departure.sh` の直接launchブロックが生成した10プロセス
  (pkillベースの旧launcher系統)がそのまま生きている。
- この状態で `watcher_supervisor.sh` が既に起動済みであれば、
  supervisorの `start_all_watchers` ループは
  `start_watcher_if_missing()` の既存pgrep冪等判定により、
  同一agent×paneの組にはnohupを試みない(重複起動しない)。
  つまり是正の反映だけでは新たなプロセスは増えず、**旧系統がその
  ままsupervisorの管理下に入らずに稼働し続ける**状態になる。

`watcher_supervisor.sh` 自体が稼働しているかは以下で確認できる:

```bash
pgrep -af "scripts/watcher_supervisor.sh"
```

## 切替の流れ(殿が手元で行うこと)

1. 上記 `pgrep -af "scripts/inbox_watcher.sh"` で現在稼働中の
   watcherプロセス一覧を確認する。
2. 次回、殿の手元で `shutsujin_departure.sh` を**再実行**する
   (通常のシステム起動・再起動手順と同じ)。このとき新版の
   `shutsujin_departure.sh` は直接launchブロックを持たないため、
   pkillも新規nohupも行わない。inbox初期化のみを行った後、
   STEP 6.6.5で `watcher_supervisor.sh` の起動確認(既に稼働中なら
   何もしない・未稼働なら起動)のみを行う。
3. 旧系統のプロセス(pkillベースの旧launcherが過去に生成した
   watcherたち)を新系統(`watcher_supervisor.sh`管理下)に一本化
   するには、**殿が手元で該当プロセスを手動終了**する必要がある
   (例: 該当PIDに対する通常のプロセス終了操作)。終了後、
   `watcher_supervisor.sh` の次回ループ(5秒以内)が
   `start_watcher_if_missing()` の冪等判定により不在を検知し、
   自動的に再起動する。
   🔴 本カードの作業(足軽・家老等のエージェント)側では
   D006によりこの手動終了を代行できない。あくまで殿の手元操作である。
4. 終了後、再度 `pgrep -af "scripts/inbox_watcher.sh"` を実行し、
   各agentにつきプロセスが1つずつ(計10)になっていることを確認する。

## 参考: 全10体の内訳確認

```bash
bash scripts/watcher_supervisor.sh --print-watchers
```

将軍(`shogun`)を含む10体(karo, ashigaru1-7, gunshi, shogun)が
一覧されることを、本カードの作業時にも実測で確認済み。
