#!/usr/bin/env python3
"""context_blanker.py 가 ContextBlanker.swift 와 어긋나지 않았는지 확인한다.

번들 DB 의 예문은 모두 앱의 빈칸 규칙을 통과하도록 만들어진 것이다. 따라서
이 포팅이 정확하다면 거의 전부 통과해야 한다. 통과율이 갑자기 떨어지면
Swift 쪽만 고치고 이 파일을 안 고친 것이다.

사용법:
    python3 Scripts/verify_blanker.py [--db path] [--show 20]
"""
import argparse
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import context_blanker as cb

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DB = os.path.join(REPO_ROOT, "Database", "v85_20260312T133124Z.db")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--show", type=int, default=15)
    args = parser.parse_args()

    conn = sqlite3.connect(args.db)
    rows = conn.execute(
        "SELECT word, exampleSentence FROM Corpus WHERE isDeleted = 0 "
        "AND exampleSentence IS NOT NULL AND TRIM(exampleSentence) <> ''"
    ).fetchall()
    conn.close()

    misses = [(w, s) for w, s in rows if not cb.contains(w, s)]
    ok = len(rows) - len(misses)
    rate = ok / len(rows) * 100 if rows else 0
    print(f"예문 {len(rows)}개 중 빈칸 생성 가능 {ok}개 ({rate:.1f}%)")
    if misses:
        print(f"\n빈칸을 만들 수 없는 예문 {len(misses)}개:")
        for w, s in misses[:args.show]:
            print(f"  {w:22} {s[:72]}")
        if len(misses) > args.show:
            print(f"  … 외 {len(misses) - args.show}개")
    return 0 if rate >= 95 else 1


if __name__ == "__main__":
    sys.exit(main())
