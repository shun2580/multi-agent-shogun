#!/usr/bin/env python3
"""
Timing events analyzer for cmd workflow
Reads logs/timing_events.jsonl and produces breakdown by cmd/task
"""

import json
import sys
from pathlib import Path
from collections import defaultdict
from datetime import datetime
from typing import Dict, List, Tuple, Optional
import re

def parse_timestamp(ts_str: str) -> datetime:
    """Parse ISO 8601 timestamp string to datetime"""
    if ts_str.endswith('+09:00'):
        ts_str = ts_str[:-6]
    elif ts_str.endswith('Z'):
        ts_str = ts_str[:-1]
    elif '+' in ts_str or ts_str.count('-') > 2:
        # Handle other timezone formats
        match = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})', ts_str)
        if match:
            ts_str = match.group(1)
    return datetime.fromisoformat(ts_str)

def timestamp_to_seconds(ts_str: str) -> float:
    """Convert ISO timestamp to seconds since epoch"""
    dt = parse_timestamp(ts_str)
    return dt.timestamp()

def read_events(jsonl_path: str) -> List[Dict]:
    """Read JSONL events file"""
    events = []
    try:
        with open(jsonl_path, 'r') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                    events.append(event)
                except json.JSONDecodeError:
                    print(f"Warning: Failed to parse JSON line: {line[:100]}", file=sys.stderr)
                    continue
    except FileNotFoundError:
        return []
    return events

def read_reports() -> Dict[Tuple[str, str], Dict]:
    """Read all task_ids from queue/reports/*.yaml files"""
    reports_dir = Path('queue/reports')
    task_ids = set()

    try:
        for yaml_file in reports_dir.glob('*.yaml'):
            with open(yaml_file, 'r') as f:
                content = f.read()
                # Simple regex extraction of task_id values
                matches = re.findall(r'task_id:\s*(.+?)(?:\n|$)', content)
                for match in matches:
                    task_id = match.strip(' "\'')
                    if task_id and task_id not in ('gunshi_qc_', 'subtask_', 'cmd_', 'parent_cmd'):
                        task_ids.add(task_id)
    except Exception as e:
        print(f"Warning: Failed to read reports: {e}", file=sys.stderr)

    return task_ids

def get_first_event(events: List[Dict], event_type: str, agent: Optional[str] = None) -> Optional[Dict]:
    """Get first event of given type, optionally filtered by agent"""
    for event in events:
        if event.get('event') == event_type:
            if agent is None or event.get('agent') == agent:
                return event
    return None

def find_rework_chain(all_events: List[Dict], task_id: str, fail_event: Dict) -> Tuple[float, Optional[Dict]]:
    """
    Find rework interval for a task that has qc_result=fail.
    Returns (rework_seconds, redo_assigned_event).

    Rework time = fail timestamp → redo task's assigned timestamp (pure wait/handling).
    Does NOT include the redo task's own handoff/generation/qc times (those are calculated separately).
    """
    fail_ts_sec = timestamp_to_seconds(fail_event['ts'])

    # Find next task in redo chain (redo_of == current task_id)
    for event in all_events:
        if (event.get('event') == 'assigned' and
            event.get('redo_of') == task_id and
            timestamp_to_seconds(event['ts']) > fail_ts_sec):

            redo_assigned_ts = timestamp_to_seconds(event['ts'])
            rework_sec = redo_assigned_ts - fail_ts_sec
            return rework_sec, event

    return 0.0, None

def analyze_task(cmd_id: str, task_id: str, events: List[Dict], all_events: List[Dict]) -> Dict:
    """Analyze timing for a single task"""
    results = {
        'cmd_id': cmd_id,
        'task_id': task_id,
        'generation_sec': None,
        'handoff_sec': None,
        'qc_sec': None,
        'rework_sec': None,
        'escalation_sec': None,
    }

    # Sort events by timestamp
    events_sorted = sorted(events, key=lambda e: timestamp_to_seconds(e['ts']))

    # Find key events (ashigaru's, not gunshi's)
    assigned_event = get_first_event(events_sorted, 'assigned')
    ashigaru_started = None
    ashigaru_submitted = None
    gunshi_started = None
    gunshi_submitted = None
    gunshi_fail_submitted = None

    # Separate ashigaru and gunshi events
    for event in events_sorted:
        agent = event.get('agent')
        event_type = event.get('event')

        if agent == 'ashigaru1' or agent == 'ashigaru2' or agent == 'ashigaru3' or agent == 'ashigaru4' or agent == 'ashigaru5' or agent == 'ashigaru6' or agent == 'ashigaru7' or (agent and 'ashigaru' in agent):
            if event_type == 'agent_started' and ashigaru_started is None:
                ashigaru_started = event
            elif event_type == 'report_submitted' and ashigaru_submitted is None:
                ashigaru_submitted = event
        elif agent == 'gunshi':
            if event_type == 'agent_started' and gunshi_started is None:
                gunshi_started = event
            elif event_type == 'report_submitted':
                if gunshi_submitted is None:
                    gunshi_submitted = event
                if event.get('qc_result') == 'fail' and gunshi_fail_submitted is None:
                    gunshi_fail_submitted = event

    # ① Generation time (ashigaru着手 ~ ashigaru報告)
    if ashigaru_started and ashigaru_submitted:
        start_sec = timestamp_to_seconds(ashigaru_started['ts'])
        submit_sec = timestamp_to_seconds(ashigaru_submitted['ts'])
        results['generation_sec'] = submit_sec - start_sec

    # ② Handoff wait (割当 ~ ashigaru着手)
    if assigned_event and ashigaru_started:
        assign_sec = timestamp_to_seconds(assigned_event['ts'])
        start_sec = timestamp_to_seconds(ashigaru_started['ts'])
        results['handoff_sec'] = start_sec - assign_sec

    # ③ Gunshi QC (gunshi's agent_started ~ report_submitted)
    if gunshi_started and gunshi_submitted:
        gunshi_start_sec = timestamp_to_seconds(gunshi_started['ts'])
        gunshi_submit_sec = timestamp_to_seconds(gunshi_submitted['ts'])
        results['qc_sec'] = gunshi_submit_sec - gunshi_start_sec

    # ④ Rework (gunshi fail → next redo pass in redo chain)
    if gunshi_fail_submitted:
        rework_sec, next_pass = find_rework_chain(all_events, task_id, gunshi_fail_submitted)
        if rework_sec > 0:
            results['rework_sec'] = rework_sec

    # ⑤ Escalation (future: detect escalation events)
    results['escalation_sec'] = None

    return results

def group_by_task(events: List[Dict]) -> Dict[Tuple[str, str], List[Dict]]:
    """Group events by (cmd_id, task_id)"""
    grouped = defaultdict(list)
    for event in events:
        key = (event.get('cmd_id', ''), event.get('task_id', ''))
        grouped[key].append(event)
    return grouped

def calculate_unmeasurable_rate(total_task_ids: set, measured_tasks: set) -> float:
    """Calculate rate of tasks without timing events"""
    if not total_task_ids:
        return 0.0
    unmeasured_count = len(total_task_ids - measured_tasks)
    return unmeasured_count / len(total_task_ids)

def calculate_true_wallclock_per_task(grouped: Dict) -> Dict[Tuple[str, str], float]:
    """
    Calculate actual wall-clock duration (first event → last event) for each task.
    Returns dict of (cmd_id, task_id) → wall_clock_seconds
    """
    wallclock_per_task = {}
    for (cmd_id, task_id), task_events in grouped.items():
        if not task_events:
            continue
        timestamps = [timestamp_to_seconds(e['ts']) for e in task_events]
        first_ts = min(timestamps)
        last_ts = max(timestamps)
        wallclock_per_task[(cmd_id, task_id)] = last_ts - first_ts
    return wallclock_per_task

def verify_consistency(all_results: List[Dict], wallclock_per_task: Dict) -> Tuple[bool, str]:
    """
    Verify that categories sum matches actual wall-clock time per task.
    Returns (is_consistent, message)
    """
    issues = []

    for result in all_results:
        cmd_id = result['cmd_id']
        task_id = result['task_id']
        key = (cmd_id, task_id)

        # Skip tasks with no timing events
        if key not in wallclock_per_task:
            continue

        true_wallclock = wallclock_per_task[key]
        measured_sum = sum([
            result.get('generation_sec', 0) or 0,
            result.get('handoff_sec', 0) or 0,
            result.get('qc_sec', 0) or 0,
            result.get('rework_sec', 0) or 0,
            result.get('escalation_sec', 0) or 0,
        ])

        # Allow small tolerance (0.1 seconds for rounding)
        if abs(measured_sum - true_wallclock) > 0.1:
            issues.append(
                f"Task {task_id}: measured sum ({measured_sum:.1f}s) != "
                f"wall-clock ({true_wallclock:.1f}s), delta={measured_sum - true_wallclock:.1f}s"
            )

    if issues:
        return False, "Inconsistencies found:\n  " + "\n  ".join(issues)
    else:
        return True, "All tasks: measured categories sum ≈ wall-clock time ✓"

def main():
    # Read events
    events = read_events('logs/timing_events.jsonl')

    if not events:
        print("Warning: No timing events found in logs/timing_events.jsonl", file=sys.stderr)

    # Read task_ids from reports
    all_task_ids = read_reports()

    # Group events by task
    grouped = group_by_task(events)

    # Calculate true wall-clock time per task
    wallclock_per_task = calculate_true_wallclock_per_task(grouped)

    # Analyze each task
    all_results = []
    measured_tasks = set()
    for (cmd_id, task_id), task_events in grouped.items():
        if task_id:
            result = analyze_task(cmd_id, task_id, task_events, events)
            all_results.append(result)
            measured_tasks.add(task_id)

    # Calculate aggregates by cmd
    cmd_aggregates = defaultdict(lambda: {
        'generation_sec': 0,
        'handoff_sec': 0,
        'qc_sec': 0,
        'rework_sec': 0,
        'escalation_sec': 0,
        'count': 0,
    })

    total_aggregates = {
        'generation_sec': 0,
        'handoff_sec': 0,
        'qc_sec': 0,
        'rework_sec': 0,
        'escalation_sec': 0,
        'unmeasurable_sec': 0,
    }

    for result in all_results:
        cmd_id = result['cmd_id']
        for key in ['generation_sec', 'handoff_sec', 'qc_sec', 'rework_sec', 'escalation_sec']:
            val = result.get(key)
            if val is not None:
                cmd_aggregates[cmd_id][key] += val
                total_aggregates[key] += val
        cmd_aggregates[cmd_id]['count'] += 1

    # Calculate unmeasurable rate
    unmeasurable_rate = calculate_unmeasurable_rate(all_task_ids, measured_tasks)

    # Print human-readable summary
    print("=" * 60)
    print("Timing Analysis Summary")
    print("=" * 60)
    print()

    print(f"Total tasks found in reports: {len(all_task_ids)}")
    print(f"Tasks with timing events: {len(measured_tasks)}")
    print(f"Unmeasurable tasks: {len(all_task_ids) - len(measured_tasks)}")
    print(f"Unmeasurable rate: {unmeasurable_rate*100:.1f}%")
    print()

    print("Breakdown by Category (all commands):")
    print("-" * 60)

    total_seconds = sum([
        total_aggregates['generation_sec'],
        total_aggregates['handoff_sec'],
        total_aggregates['qc_sec'],
        total_aggregates['rework_sec'],
        total_aggregates['escalation_sec'],
    ])

    categories = [
        ('① Generation (real work)', total_aggregates['generation_sec']),
        ('② Handoff wait (queue)', total_aggregates['handoff_sec']),
        ('③ Gunshi QC', total_aggregates['qc_sec']),
        ('④ Rework (fail→pass)', total_aggregates['rework_sec']),
        ('⑤ Escalation', total_aggregates['escalation_sec']),
    ]

    for name, seconds in categories:
        pct = (seconds / total_seconds * 100) if total_seconds > 0 else 0
        print(f"{name:30s}: {seconds:8.1f}s ({pct:6.1f}%)")

    print("-" * 60)
    print(f"{'Total measured time':30s}: {total_seconds:8.1f}s (100.0%)")

    # Real consistency check: measured categories vs actual wall-clock
    print()
    print("Internal Consistency Check:")
    print("-" * 60)
    is_consistent, consistency_msg = verify_consistency(all_results, wallclock_per_task)
    print(consistency_msg)

    # Check for obvious data quality issues
    if total_seconds > 0:
        if total_aggregates['rework_sec'] > total_seconds * 0.5:
            print(f"⚠ Warning: Rework > 50% of total time ({total_aggregates['rework_sec']/total_seconds*100:.1f}%)")
            print(f"  This may indicate issues in the rework chain calculation.")
    else:
        print("ℹ No timing events recorded")

    print()
    print("Per-Command Breakdown:")
    print("-" * 60)
    for cmd_id in sorted(k for k in cmd_aggregates.keys() if k):
        agg = cmd_aggregates[cmd_id]
        print(f"{cmd_id}: {agg['count']} tasks, "
              f"gen={agg['generation_sec']:.0f}s, "
              f"wait={agg['handoff_sec']:.0f}s, "
              f"qc={agg['qc_sec']:.0f}s, "
              f"rework={agg['rework_sec']:.0f}s")

if __name__ == '__main__':
    main()
