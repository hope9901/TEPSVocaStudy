#!/usr/bin/env python3
"""DB 의 예문을 word→sentence JSON 으로 빼낸다.

생성해 둔 예문을 DB 바깥에 보관하는 용도다. 단어 문자열로 저장하므로, 나중에
단어집을 바꾸거나 DB 를 다시 만들어도 load_sentences.py 로 그대로 다시 넣을
수 있다. 행 id 에 묶이지 않는다.

사용법:
    python3 Scripts/export_sentences.py                      # 전체
    python3 Scripts/export_sentences.py --out backup.json
    python3 Scripts/export_sentences.py --only-usable        # 앱이 빈칸 만들 수 있는 것만
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sentence_tools as st


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=st.DEFAULT_DB)
    parser.add_argument("--out", default="sentences.json")
    parser.add_argument("--only-usable", action="store_true",
                        help="앱이 실제로 빈칸을 만들 수 있는 문장만 내보낸다")
    args = parser.parse_args()

    conn = st.connect(args.db)
    rows = conn.execute(
        "SELECT word, exampleSentence FROM Corpus "
        "WHERE vocabularyId = ? AND isDeleted = 0 "
        "AND exampleSentence IS NOT NULL AND TRIM(exampleSentence) <> '' "
        "ORDER BY id",
        (st.UNIFIED_VOCAB_ID,),
    ).fetchall()
    conn.close()

    out, skipped = [], 0
    for word, sentence in rows:
        if args.only_usable and not st.locate_word(sentence, word):
            skipped += 1
            continue
        out.append({"word": word, "sentence": sentence})

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)

    print(f"{len(out)}개 예문을 {args.out} 에 저장했습니다.")
    if skipped:
        print(f"빈칸을 만들 수 없어 제외한 문장 {skipped}개")
    print("되넣기:  python3 Scripts/load_sentences.py " + args.out)


if __name__ == "__main__":
    main()
