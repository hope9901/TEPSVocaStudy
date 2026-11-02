#!/usr/bin/env python3
"""번들 DB 의 단어 목록을 강의 단어집으로 교체한다. 시스템 코드는 건드리지 않는다.

왜 이렇게 하나 — DatabaseManager.migrateBundledContentIfNeeded() 는 번들 DB 를
ATTACH 해서 **id 가 같은 행을 UPDATE** 하고, **없는 id 를 INSERT** 한다. 행을
지우는 일은 절대 없다. 따라서:

  * 남는 단어는 기존 id 를 그대로 써야 한다. 그래야 기기에 쌓인 학습 진도
    (WordProgress) 가 그 단어에 계속 붙어 있는다.
  * 빠지는 단어는 **isDeleted = 1 로 남겨야** 한다. 번들에서 행을 없애면
    기기에서는 그냥 예전 그대로 살아 있게 된다.
  * 빠지는 단어의 예문·한글번역은 지우지 않는다. 나중에 되살리기 쉽다.

사용법:
    python3 Scripts/rebuild_corpus.py Scripts/data/course_wordlist.json
    python3 Scripts/rebuild_corpus.py <wordlist.json> --db path --dry-run
"""
import argparse
import datetime
import hashlib
import json
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import context_blanker as cb

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DB = os.path.join(REPO_ROOT, "Database", "v85_20260312T133124Z.db")
UNIFIED_VOCAB_ID = "unified-teps-vocab-id"


def lemma_candidates(word):
    """활용형 표제어에서 원형 후보를 뽑는다."""
    w = word.strip().lower()
    out = []
    # -ly 는 다루지 않는다. "timely" 는 "time" 의 활용형이 아니라 다른 단어다.
    for suffix, adds in (("ied", ["y"]), ("ies", ["y"]), ("ing", ["", "e"]),
                         ("ed", ["", "e"]), ("es", ["", "e"]), ("s", [""])):
        if w.endswith(suffix) and len(w) - len(suffix) >= 3:
            stem = w[: -len(suffix)]
            out += [stem + a for a in adds]
            if len(stem) > 2 and stem[-1] == stem[-2]:      # stopped → stop
                out.append(stem[:-1])
    return [k for k in dict.fromkeys(out) if k and k != w]


def normalization_block(word, pos):
    """원형으로 합치면 안 되는 경우를 가려낸다.

    활용형이라고 다 같은 단어가 아니다. 파생형이 독립된 어휘 항목이면
    원형으로 합치는 순간 그 항목이 사라진다. TEPS 는 바로 그 차이를 묻는다.
    """
    w = word.strip().lower()
    pos = (pos or "").lower()
    if "adverb" in pos:
        return "부사 (원형은 형용사 — 다른 항목)"
    if "adjective" in pos and "verb" not in pos and w.endswith("ed"):
        return "-ed 형용사 (원형은 동사 — 다른 항목)"
    if w.endswith("ing") and ("noun" in pos or "adjective" in pos):
        return "-ing 명사/형용사 (원형은 동사 — 다른 항목)"
    return None


def make_id(word):
    """같은 단어면 항상 같은 id. 다시 돌려도 행이 늘어나지 않는다."""
    h = hashlib.md5(("course-wordlist:" + word.strip().lower()).encode()).hexdigest()
    return f"{h[0:4]}-{h[4:8]}-{h[8:16]}-{h[16:20]}-{h[20:32]}"


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("wordlist")
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--keep-inflected", action="store_true",
                        help="활용형 표제어를 원형으로 합치지 않고 그대로 둔다")
    args = parser.parse_args()

    entries = json.load(open(args.wordlist, encoding="utf-8"))
    entries.sort(key=lambda e: e.get("order", 0))
    print(f"단어집: {len(entries)}개")

    conn = sqlite3.connect(args.db)
    conn.execute("PRAGMA foreign_keys = ON")

    # 기존 행을 단어별로 모은다. 살아 있는 행을 먼저 쓰고, 없으면 지워진 행을
    # 되살린다 (그 쪽이 진도를 보존할 가능성이 더 높다).
    pool = {}
    meanings = {}
    for cid, word, meaning, deleted, sentence in conn.execute(
        "SELECT id, word, meaning, isDeleted, exampleSentence FROM Corpus "
        "WHERE vocabularyId = ?", (UNIFIED_VOCAB_ID,),
    ):
        key = word.strip().lower()
        pool.setdefault(key, []).append((deleted, cid, sentence))
        meanings[key] = (word, meaning)
    for rows in pool.values():
        rows.sort(key=lambda r: r[0])          # isDeleted=0 먼저

    course_words = {e["word"].strip().lower() for e in entries}

    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    base = now - datetime.timedelta(days=1)    # 과거 시각으로 둔다

    claimed = set()
    reused = inserted = kept_sentence = took_sentence = 0
    updates, inserts = [], []
    normalized, blocked = [], []

    def free_row(key):
        for candidate in pool.get(key, []):
            if candidate[1] not in claimed:
                return candidate
        return None

    for index, entry in enumerate(entries):
        word = entry["word"].strip()
        key = word.lower()
        row = free_row(key)
        meaning, pos = entry["meaning"], entry.get("pos") or None

        # 정확히 일치하는 행이 없으면, 이 표제어가 기존 단어의 활용형인지 본다.
        # 원형 행에는 이미 예문과 한글 번역이 붙어 있으므로, 합칠 수 있으면
        # 예문을 새로 만들 필요가 없다.
        if row is None and not args.keep_inflected:
            hit = None
            for lemma in lemma_candidates(word):
                if lemma in course_words:            # 단어집에 원형이 따로 있다
                    continue
                candidate = free_row(lemma)
                if not candidate or not candidate[2]:
                    continue
                lemma_word, lemma_meaning = meanings[lemma]
                if cb.contains(lemma_word, candidate[2]):
                    hit = (candidate, lemma_word, lemma_meaning)
                    break
            if hit:
                reason = normalization_block(word, entry.get("pos"))
                if reason:
                    blocked.append((word, reason))
                else:
                    # 예문과 한글 번역이 원형 기준으로 쓰여 있으므로 표제어와
                    # 뜻도 원형 쪽을 쓴다.
                    row, word, meaning = hit[0], hit[1], hit[2]
                    pos = None
                    normalized.append((entry["word"].strip(), hit[1]))

        created = iso(base + datetime.timedelta(seconds=index))
        incoming = (entry.get("sentence") or "").strip() or None

        if row:
            _, cid, existing = row
            claimed.add(cid)
            reused += 1
            sentence = (existing or "").strip() or None
            if sentence:
                kept_sentence += 1
            elif incoming:
                sentence = incoming
                took_sentence += 1
            updates.append((word, meaning, pos, sentence, iso(now), cid))
        else:
            inserted += 1
            if incoming:
                took_sentence += 1
            inserts.append((make_id(word), UNIFIED_VOCAB_ID, word, entry["meaning"],
                            entry.get("pos") or None, incoming,
                            created, iso(now), created))

    dropped = [cid for rows in pool.values() for (_, cid, _) in rows if cid not in claimed]

    print(f"  기존 행 재사용 {reused}  (진도 유지)")
    print(f"    └ 활용형을 원형으로 합침 {len(normalized)}  (예문·번역을 그대로 얻음)")
    print(f"  새 행 추가     {inserted}")
    print(f"  제외 → isDeleted=1  {len(dropped)}")
    print(f"  예문: 기존 유지 {kept_sentence} / 단어집에서 가져옴 {took_sentence}")
    if normalized:
        print("\n  합친 표제어:")
        for i in range(0, len(normalized), 5):
            print("    " + "  ".join(f"{a}→{b}" for a, b in normalized[i:i + 5]))
    if blocked:
        print(f"\n  활용형 그대로 둔 것 {len(blocked)}:")
        seen = {}
        for w, reason in blocked:
            seen.setdefault(reason, []).append(w)
        for reason, words in seen.items():
            print(f"    {reason}: {', '.join(words)}")

    if args.dry_run:
        conn.close()
        return

    with conn:
        conn.executemany(
            "UPDATE Corpus SET word = ?, meaning = ?, pos = ?, exampleSentence = ?, "
            "isDeleted = 0, updatedAt = ? WHERE id = ?", updates)
        conn.executemany(
            "INSERT INTO Corpus (id, vocabularyId, word, meaning, pos, pronunciation, "
            '"desc", synonym, antonym, image, familiar, isDeleted, scheduledAt, '
            "updatedAt, createdAt, exampleSentence) "
            "VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL, 0, 0, ?, ?, ?, ?)",
            [(i[0], i[1], i[2], i[3], i[4], i[6], i[7], i[8], i[5]) for i in inserts])
        conn.executemany(
            "UPDATE Corpus SET isDeleted = 1, updatedAt = ? WHERE id = ?",
            [(iso(now), cid) for cid in dropped])

    # 확인
    active, = conn.execute(
        "SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0",
        (UNIFIED_VOCAB_ID,)).fetchone()
    rows = conn.execute(
        "SELECT word, exampleSentence FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0",
        (UNIFIED_VOCAB_ID,)).fetchall()
    usable = sum(1 for w, s in rows if s and cb.contains(w, s))
    trans, = conn.execute(
        "SELECT COUNT(*) FROM ExampleTranslation t JOIN Corpus c ON c.id = t.corpusId "
        "WHERE c.isDeleted = 0").fetchone()
    conn.execute("VACUUM")
    conn.close()

    print(f"\n활성 단어 {active}")
    print(f"문맥 문제로 쓸 수 있는 예문 {usable} ({usable / active * 100:.1f}%)")
    print(f"활성 단어의 한글 예문 {trans}")
    print(f"예문 생성 대상 {active - usable}")


if __name__ == "__main__":
    main()
