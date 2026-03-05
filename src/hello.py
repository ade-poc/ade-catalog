#!/usr/bin/env python3
# Hello World - ADE Demo
# This file is deployed from the feature branch via GitHub Actions + ADE

import socket
import datetime

branch = "BRANCH_PLACEHOLDER"  # replaced at deploy time

print("=" * 50)
print("  Hello World from Azure VM! Take 3")
print("=" * 50)
print(f"  Branch   : {branch}")
print(f"  Host     : {socket.gethostname()}")
print(f"  Time     : {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
print("=" * 50)
