#!/bin/sh
# Runs the trial setup on a local Postgres (port 5499) against a docs snapshot, then the checks.
# usage: sh db/test/run_local.sh path/to/docs_seed.sql
set -e
cd "$(dirname "$0")/.."
P="psql -h /tmp -p 5499 -U postgres -v ON_ERROR_STOP=1 -q"
$P -c "drop database if exists acad_test" -c "create database acad_test"
PGOPTIONS='-c client_min_messages=warning' $P -d acad_test -f test/supabase_stub.sql -f "$1" \
  -f trial/00_access_helpers.sql -f migrations/20261007_001_acad_calendar.sql \
  -f trial/10_copy_from_docs.sql -f trial/20_realtime.sql -f test/checks.sql
