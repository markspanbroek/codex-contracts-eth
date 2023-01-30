#!/bin/bash
set -e
echidna-test . --contract FuzzCollateral --config fuzzing/echidna.yaml
echidna-test . --contract FuzzMarketplace --config fuzzing/echidna.yaml
