## Why

Nothing updates the usage index while `usage.watch` is unset, so on this machine it had gone seventeen days without an update. `tusage` with no arguments then died in awk on a division by zero: the seven days it breaks down were empty, and their total was divided into. `tusage --by day` updates first, and the catch-up over the 2045 transcripts written since read for close to three minutes without a word, so it looked hung and was killed. The kill left the update's lock behind, and every report for the next five minutes came from the old index without saying so.

The updater's cost was in the programs it started per transcript, about 25 each: one awk over the whole 2.7 MB offsets table to find the transcript's offset, a stat and a subshell for its key and its modification time, a `wc` and two `tail`s for its size and its last complete line, and a grep and a cut for each of the three kinds of row it produced. The age rule for a stale lock also stopped being safe once a catch-up could last longer than five minutes: a second updater would take a live one's lock over and count every byte both of them read twice.

## What Changes

- The summary and the `--by` tables give a share of a zero total as 0%, and an empty week says `nothing in the last 7 days`.
- The updater writes its pid into the lock. A lock stays held while that pid is a running `tusage` and is taken over at once when it is not; only a lock with no pid in it still goes by its age.
- INT, TERM and HUP end an update with its lock, temporary directory and side stamp removed and nothing appended, exiting 130, 143 or 129.
- An update on a terminal with at least 100 transcripts to read (`TU_PROGRESS_MIN`) shows `tusage: reading transcripts <n>/<total>` and clears it when done.
- The updater stats all candidates in one `stat`, keys them in one awk, joins their offsets in one pass, and has `fold_rows` append its rows to the output files itself. The last complete line is found against the size taken at the start, and a read from byte 0 is cut there too, so an append landing during the update is never read past the offset written down. The same catch-up went from 165 s to 37 s, with every fact row byte-identical.

## Impact

- Affected specs: `usage-accounting`.
- Affected code: `tusage` (`complete_bytes`, `path_facets`, `AWK_KEY` in place of `transcript_key`, `stat_all` in place of `mtime_of`, `fold_rows`, `lock_stale`, `update_abort`, `update`, `AWK_FMT`, `summary`, `report_by`), `tests/tusage.sh` (section 11).
