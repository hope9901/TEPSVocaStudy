#!/usr/bin/env python3
"""직접 작성한 예문 JSON 을 검증해서 DB 에 넣는다.

generate_sentences*.py 가 모델 API 를 불러 쓰는 자리를, 사람이(또는 이
세션이) 직접 쓴 파일로 대체하는 경로다. 검증은 똑같이 sentence_tools 의
locate_word() 를 쓰므로, 앱이 빈칸을 못 만드는 문장은 저장되지 않는다.

사용법:
    python3 Scripts/load_sentences.py <batch.json> [--db path]

batch.json 형식: [{"word": "...", "sentence": "..."}, ...]
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sentence_tools as st


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("batch")
    parser.add_argument("--db", default=st.DEFAULT_DB)
    args = parser.parse_args()

    rows = json.load(open(args.batch, encoding="utf-8"))

    # 대상 단어의 id 를 찾아 붙인다 (대소문자 무시)
    conn = st.connect(args.db)
    index = {}
    for cid, word in conn.execute(
        "SELECT id, word FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0",
        (st.UNIFIED_VOCAB_ID,),
    ):
        index[word.strip().lower()] = {"id": cid, "word": word}
    conn.close()

    batch, unknown = [], []
    for r in rows:
        key = r["word"].strip().lower()
        if key in index:
            batch.append(index[key])
        else:
            unknown.append(r["word"])

    good, bad = st.filter_valid(rows, batch)
    if good:
        st.save_sentences(good, args.db)

    print(f"입력 {len(rows)} | 저장 {len(good)} | 검증실패 {len(bad)} | DB에없음 {len(unknown)}")
    for b in bad:
        print(f"  FAIL  {b['word']} :: {b['sentence']}")
    for u in unknown:
        print(f"  UNKNOWN  {u}")

    cov = st.coverage(args.db)
    print(f"커버리지: {cov['context_usable']}/{cov['total']} "
          f"({cov['context_usable'] / cov['total'] * 100:.1f}%)  남은 대상 "
          f"{len(st.fetch_words_needing_sentences(args.db))}")


if __name__ == "__main__":
    main()
