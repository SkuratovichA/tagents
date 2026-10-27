## 1. Reports

- [x] 1.1 `pct` in `AWK_FMT` gives 0 for a zero total; the summary and `report_by` use it, and the summary says `nothing in the last 7 days` (`tests/tusage.sh` 11a, 11b)

## 2. The lock

- [x] 2.1 `update` writes `$$` into the lock and `lock_stale` holds it while that pid is a running `tusage` (11c)
- [x] 2.2 `update_abort` on INT, TERM and HUP removes the lock, the temporary directory and the side stamp and exits with the signal's status (11d)

## 3. The catch-up

- [x] 3.1 `stat_all`, `AWK_KEY`, one offsets join and `fold_rows` writing its own files replace the per-transcript programs; sections 6, 8 and 10 still pass
- [x] 3.2 `complete_bytes` works against the size taken at the start, and a read from byte 0 is cut there (11e)
- [x] 3.3 Progress on a terminal (11f); to a pipe nothing (8a)
- [x] 3.4 The catch-up from the 10.10.2026 index takes 37 s against 165 s, and its fact rows are byte-identical to the old updater's

## 4. Notes

- [x] 4.1 `LEARNING.md` has an entry for the silent catch-up and the lock it left
