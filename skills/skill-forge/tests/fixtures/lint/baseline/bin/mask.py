#!/usr/bin/env python3
"""A stand-in for the vendored masker (lint fixture only).

  mask.py --help
"""
import argparse
import sys


def emit(text="", err=False):
    (sys.stderr if err else sys.stdout).write(str(text) + "\n")


def header(target, window, command=None, rows="?", partial=None):
    return f"# target:  {target}\n# window:  {window}\n# rows:    {rows}\n# partial: {partial or 'no'}"


if __name__ == "__main__":
    argparse.ArgumentParser().parse_args()
