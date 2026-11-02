#!/usr/bin/env python3
"""단어집 교체 빌더.

수집한 단어 목록(JSON)을 받아 번들 DB의 활성 단어를 통째로 갈아끼운다.
핵심은 "파일을 새로 만들지 않는다"는 것: 앱은 Documents에 같은 이름의 DB가
있으면 복사를 건너뛰고, 기기의 학습 기록은 그 파일 안에 있다. 그래서 기존
DB를 열어 행 단위로 고치고, id를 그대로 유지한다. 그러면 앱의
migrateBundledContentIfNeeded()가 id 기준으로 내용만 동기화하면서
familiar / scheduledAt(학습 진도)은 건드리지 않는다.

  - 새 목록에도 있는 기존 단어 : 행 유지(id·진도·예문 보존), 뜻/품사만 갱신
  - 새 목록에만 있는 단어      : 새 행 삽입 (familiar 0, 예문 없음)
  - 새 목록에 없는 기존 단어   : isDeleted = 1 (행은 남으므로 되돌릴 수 있음)

사용법:
    python3 Scripts/build_vocab_db.py <newset.json> <대상.db>

newset.json 형식: [{"word", "meaning", "pos", "sources", "groups"}, ...]
"""
import json
import sqlite3
import sys
import uuid
import datetime

UNIFIED_VOCAB_ID = "unified-teps-vocab-id"

# 출처를 출제빈도 순으로 정렬하기 위한 가중치. createdAt 순서가 곧
# DistractorService 의 "같은 단원" 신호라, 빈도 묶음이 섞이지 않게 한다.
SOURCE_ORDER = [
    "TEPS 기출단어집",
    "기출문제 빈출단어 1700",
    "[327점] 상위 8% 빈출단어 500",
    "[청해 파트1-2] 상위 1-4% 빈출숙어",
    "텝스 출제빈도 1순위",
]


def group_rank(group: str) -> int:
    """'출제빈도 12순위' → 12. 숫자가 없으면 맨 뒤로."""
    digits = "".join(c for c in group if c.isdigit())
    return int(digits) if digits else 999


def sort_key(entry):
    src = entry["sources"][0] if entry["sources"] else ""
    grp = entry["groups"][0] if entry["groups"] else ""
    si = SOURCE_ORDER.index(src) if src in SOURCE_ORDER else len(SOURCE_ORDER)
    return (si, group_rank(grp), entry["word"].lower())


def main(newset_path: str, db_path: str) -> None:
    entries = json.load(open(newset_path, encoding="utf-8"))
    entries.sort(key=sort_key)
    print(f"새 단어집: {len(entries)}개")

    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    # 기존 행을 소문자 단어로 색인. isDeleted 여부와 무관하게 모아야
    # 예전에 비활성화된 단어가 새 목록에 다시 들어와도 행을 재사용한다.
    existing = {}
    for row in cur.execute(
        "SELECT id, word, isDeleted FROM Corpus WHERE vocabularyId = ?",
        (UNIFIED_VOCAB_ID,),
    ):
        key = row[1].strip().lower()
        # 활성 행을 우선 채택 (중복 단어가 있을 수 있음)
        if key not in existing or row[2] == 0:
            existing[key] = row[0]

    now = datetime.datetime.now(datetime.timezone.utc)
    now_str = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    kept, added = 0, 0
    new_keys = set()

    for index, e in enumerate(entries):
        key = e["word"].strip().lower()
        new_keys.add(key)
        desc = " / ".join(e["sources"] + e["groups"]) or None
        # 수집 순서를 1초 간격 createdAt 으로 기록해 "같은 단원" 신호를 살린다.
        # 반드시 과거 시각이어야 한다: scheduledAt 이 미래면 그 단어는 세션에
        # 아예 선택되지 않는다(LEARNING 으로 분류됨).
        created = (now - datetime.timedelta(seconds=len(entries) - index)).strftime("%Y-%m-%dT%H:%M:%SZ")

        if key in existing:
            cur.execute(
                """UPDATE Corpus
                      SET word = ?, meaning = ?, pos = ?, "desc" = ?,
                          isDeleted = 0, updatedAt = ?
                    WHERE id = ?;""",
                (e["word"], e["meaning"], e.get("pos"), desc, now_str, existing[key]),
            )
            kept += 1
        else:
            cur.execute(
                """INSERT INTO Corpus
                       (id, vocabularyId, word, meaning, pos, pronunciation, "desc",
                        synonym, antonym, image, familiar, isDeleted, scheduledAt,
                        updatedAt, createdAt, exampleSentence)
                   VALUES (?, ?, ?, ?, ?, NULL, ?, NULL, NULL, NULL, 0, 0, ?, ?, ?, NULL);""",
                (str(uuid.uuid4()).lower(), UNIFIED_VOCAB_ID, e["word"], e["meaning"],
                 e.get("pos"), desc, created, now_str, created),
            )
            added += 1

    # 새 목록에 없는 기존 단어는 비활성화 (행은 남겨 되돌릴 수 있게)
    dropped = 0
    for row in cur.execute(
        "SELECT id, word FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0",
        (UNIFIED_VOCAB_ID,),
    ).fetchall():
        if row[1].strip().lower() not in new_keys:
            cur.execute(
                'UPDATE Corpus SET isDeleted = 1, updatedAt = ? WHERE id = ?;',
                (now_str, row[0]),
            )
            dropped += 1

    # Vocabulary 요약 갱신 (앱의 updateVocabularyStatistics 와 같은 기준)
    total = cur.execute(
        "SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0",
        (UNIFIED_VOCAB_ID,),
    ).fetchone()[0]
    familiar = cur.execute(
        "SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0 AND familiar >= 3",
        (UNIFIED_VOCAB_ID,),
    ).fetchone()[0]
    cur.execute(
        """UPDATE Vocabulary
              SET total = ?, nFamiliar = ?, nUnfamiliar = ?, updatedAt = ?
            WHERE id = ?;""",
        (total, familiar, total - familiar, now_str, UNIFIED_VOCAB_ID),
    )

    conn.commit()

    with_example = cur.execute(
        """SELECT COUNT(*) FROM Corpus
            WHERE vocabularyId = ? AND isDeleted = 0
              AND exampleSentence IS NOT NULL AND exampleSentence <> ''""",
        (UNIFIED_VOCAB_ID,),
    ).fetchone()[0]
    with_pos = cur.execute(
        """SELECT COUNT(*) FROM Corpus
            WHERE vocabularyId = ? AND isDeleted = 0 AND pos IS NOT NULL""",
        (UNIFIED_VOCAB_ID,),
    ).fetchone()[0]
    conn.close()

    print(f"  기존 행 재사용(진도 보존): {kept}")
    print(f"  신규 삽입                : {added}")
    print(f"  비활성화                 : {dropped}")
    print(f"활성 단어 {total}개 | 예문 {with_example} ({with_example / total * 100:.1f}%) | 품사 {with_pos}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
