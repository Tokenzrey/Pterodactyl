#!/usr/bin/env bash
# Fixture for tests/t_docs.sh: one command with no docs section, one message the docs can quote.
cmd_start() { err "fixture says hello"; }
cmd_frob() { :; }
