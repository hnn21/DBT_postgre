# Graph Report - D:\PTDL\DBT_postgre\dwh_project  (2026-07-20)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 26 nodes · 37 edges · 8 communities (5 shown, 3 thin omitted)
- Extraction: 78% EXTRACTED · 22% INFERRED · 0% AMBIGUOUS · INFERRED: 8 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `9b514c65`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- load_raw.py
- resolve_mode
- test_load_raw.py
- check_conn.py
- compare.py
- _load_env_file

## God Nodes (most connected - your core abstractions)
1. `resolve_mode()` - 11 edges
2. `main()` - 5 edges
3. `_copy_rows()` - 3 edges
4. `full_load()` - 3 edges
5. `range_load()` - 3 edges
6. `_load_env_file()` - 2 edges
7. `parse_args()` - 2 edges
8. `test_full_when_no_args()` - 2 edges
9. `test_days_window_from_today()` - 2 edges
10. `test_explicit_range()` - 2 edges

## Surprising Connections (you probably didn't know these)
- `test_days_window_from_today()` --calls--> `resolve_mode()`  [INFERRED]
  el/test_load_raw.py → el/load_raw.py
- `test_explicit_range()` --calls--> `resolve_mode()`  [INFERRED]
  el/test_load_raw.py → el/load_raw.py
- `test_from_after_to_rejected()` --calls--> `resolve_mode()`  [INFERRED]
  el/test_load_raw.py → el/load_raw.py
- `test_from_without_to_rejected()` --calls--> `resolve_mode()`  [INFERRED]
  el/test_load_raw.py → el/load_raw.py
- `test_days_non_positive_rejected()` --calls--> `resolve_mode()`  [INFERRED]
  el/test_load_raw.py → el/load_raw.py

## Import Cycles
- None detected.

## Communities (8 total, 3 thin omitted)

### Community 0 - "load_raw.py"
Cohesion: 0.52
Nodes (6): _copy_rows(), full_load(), main(), parse_args(), range_load(), EL: load 4 bảng MySQL (tiktok_dashboard) -> schema `raw` trên PostgreSQL.  3 chế

### Community 1 - "resolve_mode"
Cohesion: 0.33
Nodes (6): Trả ('full', None, None) hoặc ('range', date_from, date_to). Raise ValueError kh, resolve_mode(), test_days_non_positive_rejected(), test_days_with_range_rejected(), test_full_when_no_args(), test_to_without_from_rejected()

### Community 2 - "test_load_raw.py"
Cohesion: 0.40
Nodes (4): test_days_window_from_today(), test_explicit_range(), test_from_after_to_rejected(), test_from_without_to_rejected()

## Knowledge Gaps
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `resolve_mode()` connect `resolve_mode` to `load_raw.py`, `test_load_raw.py`?**
  _High betweenness centrality (0.320) - this node is a cross-community bridge._
- **Why does `_load_env_file()` connect `_load_env_file` to `load_raw.py`?**
  _High betweenness centrality (0.073) - this node is a cross-community bridge._
- **Why does `main()` connect `load_raw.py` to `resolve_mode`?**
  _High betweenness centrality (0.041) - this node is a cross-community bridge._
- **Are the 8 inferred relationships involving `resolve_mode()` (e.g. with `test_days_non_positive_rejected()` and `test_days_window_from_today()`) actually correct?**
  _`resolve_mode()` has 8 INFERRED edges - model-reasoned connections that need verification._