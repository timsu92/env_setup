# Sourced by the bash tests that report one row per check in the form
# tests/run counts: `PASS [label] what` or `FAIL [label] what -> got`. Any bad
# row sets fail=1; the test exits with it.
fail=0
pass() { echo "PASS [$1] $2"; }
bad()  { echo "FAIL [$1] $2 -> $3"; fail=1; }
