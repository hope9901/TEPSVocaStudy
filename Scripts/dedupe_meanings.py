#!/usr/bin/env python3
"""Dedupe meaning variants in the Corpus table.

Meanings imported from multiple generation runs ended up as the same
translation repeated many times, joined with the "﹒" separator (up to ~250
chars). This script splits each meaning into variants (ignoring "﹒" inside
parentheses, where it is used as a word separator like "(문제﹒갈등을)"),
drops exact duplicates and variants fully contained in a longer variant,
and writes the cleaned meaning back.

Usage:
    python3 dedupe_meanings.py <path-to-db> [--dry-run]
"""

import sqlite3
import sys

SEPARATOR = "﹒"
OPEN_PARENS = "(（"
CLOSE_PARENS = ")）"


def split_variants(meaning: str) -> list[str]:
    """Split on the separator, but not inside parentheses."""
    variants = []
    current = []
    depth = 0
    for ch in meaning:
        if ch in OPEN_PARENS:
            depth += 1
        elif ch in CLOSE_PARENS:
            depth = max(0, depth - 1)
        if ch == SEPARATOR and depth == 0:
            variants.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
    variants.append("".join(current).strip())
    return [v for v in variants if v]


def dedupe(meaning: str) -> str:
    variants = split_variants(meaning)

    # Drop exact duplicates, keeping first-seen order
    seen = set()
    unique = []
    for v in variants:
        if v not in seen:
            seen.add(v)
            unique.append(v)

    # Drop variants fully contained in another (e.g. "편향된" inside
    # "(특정 관점을 지지하는) 편향된", or "포기하다" inside "완전히 포기하다")
    survivors = [
        v for v in unique
        if not any(v != other and v in other for other in unique)
    ]

    return SEPARATOR.join(survivors) if survivors else meaning


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    db_path = sys.argv[1]
    dry_run = "--dry-run" in sys.argv

    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        "SELECT id, word, meaning FROM Corpus WHERE meaning LIKE ?",
        (f"%{SEPARATOR}%",),
    ).fetchall()

    changed = 0
    max_before = max_after = 0
    for row_id, word, meaning in rows:
        cleaned = dedupe(meaning)
        max_before = max(max_before, len(meaning))
        max_after = max(max_after, len(cleaned))
        if cleaned != meaning:
            changed += 1
            if changed <= 5:
                print(f"[{word}]\n  before ({len(meaning)}): {meaning}\n  after  ({len(cleaned)}): {cleaned}\n")
            if not dry_run:
                conn.execute(
                    "UPDATE Corpus SET meaning = ? WHERE id = ?",
                    (cleaned, row_id),
                )

    if not dry_run:
        conn.commit()
    conn.close()

    mode = "DRY RUN — no changes written" if dry_run else "updated"
    print(f"{changed}/{len(rows)} meanings {mode}; longest meaning {max_before} -> {max_after} chars")


if __name__ == "__main__":
    main()
