#!/bin/bash

# For checking this file is sourced.
export DJPLUS_ENV_SOURCED=1

# Set directory paths.
export DJPLUS_ROOT=$PWD
export DJPLUS_KERNEL=$DJPLUS_ROOT/djournalplus-kernel.code

# Add binary to env path
export PATH=bin:$PATH
