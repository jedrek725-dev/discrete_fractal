#!/bin/sh
# Simple end-to-end checks: expected output and exit codes.
set -u
BIN=./discrete_fractal
fail=0

check() {   # check <description> <args> <input> <expected output>
    out=$(printf "$3" | timeout 5 $BIN $2)
    if [ "$out" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1: got '$out'"; fail=1; fi
}

check_error() {   # check_error <description> <args> <input>
    printf "$3" | timeout 5 $BIN $2 > /dev/null 2>&1
    if [ $? -eq 1 ]; then echo "ok   $1"; else echo "FAIL $1: expected exit code 1"; fail=1; fi
}

check "example from the assignment"   "4"          'A\nAAB\nBA\n'  "ABAABABA"
check "zero iterations"               "0"          'XYZ\nXA\n'     "XYZ"
check "empty initial string"          "3"          '\nAB\n'        ""
check "symbol dying after 2 steps"    "5"          'AB\nAC\nC\n'   "B"
check "huge n on a 2-cycle (fast)"    "4294967295" 'A\nAB\nBA\n'   "B"

check_error "missing argument"        ""           'A\n'
check_error "n above 2^32-1"          "4294967296" 'A\n'
check_error "non-numeric argument"    "12x"        'A\n'
check_error "duplicate rule"          "1"          'A\nAB\nAC\n'
check_error "missing final newline"   "1"          'A'

exit $fail
