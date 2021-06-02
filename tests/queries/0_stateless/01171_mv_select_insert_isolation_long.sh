#!/usr/bin/env bash

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CURDIR"/../shell_config.sh

set -e

$CLICKHOUSE_CLIENT --query "DROP TABLE IF EXISTS src";
$CLICKHOUSE_CLIENT --query "DROP TABLE IF EXISTS dst";
$CLICKHOUSE_CLIENT --query "DROP TABLE IF EXISTS mv";
$CLICKHOUSE_CLIENT --query "CREATE TABLE src (n Int8, m Int8, CONSTRAINT c CHECK xxHash32(n+m) % 8 != 0) ENGINE=MergeTree ORDER BY n PARTITION BY 0 < n";
$CLICKHOUSE_CLIENT --query "CREATE TABLE dst (nm Int16, CONSTRAINT c CHECK xxHash32(nm) % 8 != 0) ENGINE=MergeTree ORDER BY nm";
$CLICKHOUSE_CLIENT --query "CREATE MATERIALIZED VIEW mv TO dst (nm Int16) AS SELECT n*m AS nm FROM src";

$CLICKHOUSE_CLIENT --query "CREATE TABLE tmp (x UInt8, nm Int16) ENGINE=MergeTree ORDER BY (x, nm)"

$CLICKHOUSE_CLIENT --query "INSERT INTO src VALUES (0, 0)"

# some transactions will fail due to constraint
function thread_insert_commit()
{
    for i in {1..100}; do
        $CLICKHOUSE_CLIENT --multiquery --query "
        BEGIN TRANSACTION;
        INSERT INTO src VALUES ($i, $1);
        SELECT throwIf((SELECT sum(nm) FROM mv) != $(($i * $1))) FORMAT Null;
        INSERT INTO src VALUES (-$i, $1);
        COMMIT;" 2>&1| grep -Fv "is violated at row" | grep -Fv "Transaction is not in RUNNING state" | grep -F "Received from " ||:
    done
}

function thread_insert_rollback()
{
    for _ in {1..100}; do
        $CLICKHOUSE_CLIENT --multiquery --query "
        BEGIN TRANSACTION;
        INSERT INTO src VALUES (42, $1);
        SELECT throwIf((SELECT count() FROM src WHERE n=42 AND m=$1) != 1) FORMAT Null;
        ROLLBACK;"
    done
}

# make merges more aggressive
function thread_optimize()
{
    trap "exit 0" INT
    while true; do
        optimize_query="OPTIMIZE TABLE src"
        if (( RANDOM % 2 )); then
            optimize_query="OPTIMIZE TABLE dst"
        fi
        if (( RANDOM % 2 )); then
            optimize_query="$optimize_query FINAL"
        fi
        action="COMMIT"
        if (( RANDOM % 2 )); then
            action="ROLLBACK"
        fi

        $CLICKHOUSE_CLIENT --multiquery --query "
        BEGIN TRANSACTION;
        $optimize_query;
        $action;
        "
        sleep 0.$RANDOM;
    done
}

function thread_select()
{
    trap "exit 0" INT
    while true; do
        $CLICKHOUSE_CLIENT --multiquery --query "
        BEGIN TRANSACTION;
        SELECT throwIf((SELECT (sum(n), count() % 2) FROM src) != (0, 1)) FORMAT Null;
        SELECT throwIf((SELECT (sum(nm), count() % 2) FROM mv) != (0, 1)) FORMAT Null;
        SELECT throwIf((SELECT (sum(nm), count() % 2) FROM dst) != (0, 1)) FORMAT Null;
        SELECT throwIf((SELECT arraySort(groupArray(nm)) FROM mv) != (SELECT arraySort(groupArray(nm)) FROM dst)) FORMAT Null;
        SELECT throwIf((SELECT arraySort(groupArray(nm)) FROM mv) != (SELECT arraySort(groupArray(n*m)) FROM src)) FORMAT Null;
        COMMIT;" || $CLICKHOUSE_CLIENT -q "SELECT 'src', arraySort(groupArray(n*m)) FROM src UNION ALL SELECT 'mv', arraySort(groupArray(nm)) FROM mv"
    done
}

function thread_select_insert()
{
    trap "exit 0" INT
    while true; do
        $CLICKHOUSE_CLIENT --multiquery --query "
        BEGIN TRANSACTION;
        SELECT throwIf((SELECT count() FROM tmp) != 0) FORMAT Null;
        INSERT INTO tmp SELECT 1, n*m FROM src;
        INSERT INTO tmp SELECT 2, nm FROM mv;
        INSERT INTO tmp SELECT 3, nm FROM dst;
        INSERT INTO tmp SELECT 4, (*,).1 FROM (SELECT n*m FROM src UNION ALL SELECT nm FROM mv UNION ALL SELECT nm FROM dst);
        SELECT throwIf((SELECT countDistinct(x) FROM tmp) != 4) FORMAT Null;

        -- now check that all results are the same
        SELECT throwIf(1 != (SELECT countDistinct(arr) FROM (SELECT x, arraySort(groupArray(nm)) AS arr FROM tmp WHERE x!=4 GROUP BY x))) FORMAT Null;
        SELECT throwIf((SELECT count(), sum(nm) FROM tmp WHERE x=4) != (SELECT count(), sum(nm) FROM tmp WHERE x!=4)) FORMAT Null;
        ROLLBACK;" || $CLICKHOUSE_CLIENT -q "SELECT x, arraySort(groupArray(nm)) AS arr FROM tmp GROUP BY x"
    done
}

thread_insert_commit 1 & PID_1=$!
thread_insert_commit 2 & PID_2=$!
thread_insert_rollback 3 & PID_3=$!

thread_optimize & PID_4=$!
thread_select & PID_5=$!
thread_select_insert & PID_6=$!
sleep 0.$RANDOM;
thread_select & PID_7=$!
thread_select_insert & PID_8=$!

wait $PID_1 && wait $PID_2 && wait $PID_3
kill -INT $PID_4
kill -INT $PID_5
kill -INT $PID_6
kill -INT $PID_7
kill -INT $PID_8
wait

$CLICKHOUSE_CLIENT --multiquery --query "
BEGIN TRANSACTION;
SELECT count(), sum(n), sum(m=1), sum(m=2), sum(m=3) FROM src;
SELECT count(), sum(nm) FROM mv";

$CLICKHOUSE_CLIENT --query "DROP TABLE src";
$CLICKHOUSE_CLIENT --query "DROP TABLE dst";
$CLICKHOUSE_CLIENT --query "DROP TABLE mv";
