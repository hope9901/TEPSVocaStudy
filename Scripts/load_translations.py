#!/usr/bin/env python3
"""예문의 한글 번역 JSON 을 검증해서 ExampleTranslation 에 넣는다.

앱은 fetchExampleTranslations() 로 corpusId → 번역 맵을 읽어 예문 아래에
보여준다. 번역은 corpusId 로 저장되지만, 이 파일은 **단어 문자열**로 받는다.
단어장을 다시 만들면 id 가 바뀌므로, 사람이 쓰는 쪽은 id 를 몰라야 한다.

검증 내용:
  * 그 단어가 활성 상태로 DB 에 있는지
  * 그 단어에 예문이 실제로 있는지 (예문 없는 번역은 보일 자리가 없다)
  * 번역에 한글이 들어 있는지 (영어를 그대로 복사한 경우를 걸러낸다)

사용법:
    python3 Scripts/load_translations.py <batch.json> [--db path]

batch.json 형식: [{"word": "...", "translation": "..."}, ...]
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sentence_tools as st

HANGUL = range(0xAC00, 0xD7A4)


def has_hangul(text):
    return any(ord(ch) in HANGUL or 0x3131 <= ord(ch) <= 0x318E for ch in text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("batch")
    parser.add_argument("--db", default=st.DEFAULT_DB)
    args = parser.parse_args()

    rows = json.load(open(args.batch, encoding="utf-8"))

    conn = st.connect(args.db)
    index = {}
    for cid, word, sentence in conn.execute(
        "SELECT id, word, exampleSentence FROM Corpus "
        "WHERE vocabularyId = ? AND isDeleted = 0",
        (st.UNIFIED_VOCAB_ID,),
    ):
        index[word.strip().lower()] = (cid, (sentence or "").strip())

    good, bad, unknown = [], [], []
    for item in rows:
        word = item["word"].strip()
        translation = (item.get("translation") or "").strip()
        entry = index.get(word.lower())
        if not entry:
            unknown.append(word)
            continue
        cid, sentence = entry
        if not sentence:
            bad.append((word, "예문이 없음"))
        elif not translation:
            bad.append((word, "번역이 비어 있음"))
        elif not has_hangul(translation):
            bad.append((word, "한글이 없음"))
        else:
            good.append((cid, translation))

    if good:
        with conn:
            conn.executemany(
                "INSERT INTO ExampleTranslation (corpusId, translation) VALUES (?, ?) "
                "ON CONFLICT(corpusId) DO UPDATE SET translation = excluded.translation",
                good)

    total, = conn.execute(
        "SELECT COUNT(*) FROM Corpus c JOIN ExampleTranslation t ON t.corpusId = c.id "
        "WHERE c.vocabularyId = ? AND c.isDeleted = 0", (st.UNIFIED_VOCAB_ID,)).fetchone()
    active, = conn.execute(
        "SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0",
        (st.UNIFIED_VOCAB_ID,)).fetchone()
    conn.close()

    print(f"입력 {len(rows)} | 저장 {len(good)} | 검증실패 {len(bad)} | DB에없음 {len(unknown)}")
    for word, why in bad:
        print(f"  FAIL  {word} :: {why}")
    for word in unknown:
        print(f"  UNKNOWN  {word}")
    print(f"번역 커버리지: {total}/{active} ({total / active * 100:.1f}%)  "
          f"남은 대상 {active - total}")


if __name__ == "__main__":
    main()
