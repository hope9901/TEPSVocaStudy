#!/usr/bin/env python3
"""Gemini 로 예문을 생성해 DB 에 채운다.

앞선 버전과 달라진 점:
  - DB 경로를 인자/환경변수로 받는다 (예전엔 Windows 경로가 박혀 있었음)
  - 품사를 프롬프트에 같이 넘긴다 (새 단어집이 품사를 제공)
  - 생성된 문장에 대상 단어가 실제로 들어 있는지 앱과 같은 규칙으로 검증하고,
    실패한 단어만 한 번 더 요청한다
  - 예문이 있어도 단어를 못 찾는 기존 행까지 대상에 포함한다

사용법:
    export GEMINI_API_KEY=...            # 또는 Scripts/.env 에 저장
    python3 Scripts/generate_sentences_gemini.py              # 전체
    python3 Scripts/generate_sentences_gemini.py --limit 40   # 맛보기
    python3 Scripts/generate_sentences_gemini.py --db path/to.db
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sentence_tools as st

try:
    import google.generativeai as genai
except ImportError:
    print("'google-generativeai' 가 없습니다.  pip install google-generativeai")
    genai = None

MODEL_NAME = "gemini-2.5-flash"
BATCH_SIZE = 40
BATCH_PAUSE = 5          # 무료 티어 15 RPM 대응


def load_api_key():
    if os.environ.get("GEMINI_API_KEY"):
        return os.environ["GEMINI_API_KEY"]
    env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if os.path.exists(env_path):
        for line in open(env_path, encoding="utf-8"):
            if line.strip().startswith("GEMINI_API_KEY="):
                return line.split("=", 1)[1].strip().strip("\"'")
    return None


def ask(model, batch, stricter=False):
    prompt = st.build_prompt(batch)
    if stricter:
        prompt += ("\nThe previous attempt failed because the sentences did not contain "
                   "the target word itself. Write the target word literally, exactly as "
                   "given (an inflected form of that same word is acceptable).\n")

    for attempt in range(5):
        try:
            response = model.generate_content(
                prompt,
                generation_config=genai.GenerationConfig(
                    response_mime_type="application/json", temperature=0.3),
            )
            text = response.text.strip()
            if text.startswith("```"):
                text = "\n".join(text.split("\n")[1:-1]).strip()
            return json.loads(text)
        except Exception as exc:                       # noqa: BLE001
            wait = 5 * (2 ** attempt)
            print(f"    API 실패 ({attempt + 1}/5): {exc}")
            if attempt < 4:
                print(f"    {wait}초 후 재시도")
                time.sleep(wait)
    return []


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=st.DEFAULT_DB)
    parser.add_argument("--limit", type=int, default=None, help="처리할 단어 수 제한")
    parser.add_argument("--dry-run", action="store_true", help="대상만 세고 끝낸다")
    args = parser.parse_args()

    before = st.coverage(args.db)
    print(f"DB: {args.db}")
    print(f"시작 커버리지: 활성 {before['total']} / 예문 {before['has_sentence']} / "
          f"문맥 사용가능 {before['context_usable']} "
          f"({before['context_usable'] / before['total'] * 100:.1f}%)")

    words = st.fetch_words_needing_sentences(args.db, args.limit)
    print(f"생성 대상: {len(words)}개")
    if args.dry_run or not words:
        return
    if not genai:
        return

    api_key = load_api_key()
    if not api_key:
        print("GEMINI_API_KEY 가 설정되지 않았습니다. "
              "https://aistudio.google.com/ 에서 발급 후 환경변수나 Scripts/.env 에 넣으세요.")
        return

    genai.configure(api_key=api_key)
    model = genai.GenerativeModel(MODEL_NAME)

    saved, rejected_total = 0, 0
    started = time.time()

    for i in range(0, len(words), BATCH_SIZE):
        batch = words[i:i + BATCH_SIZE]
        n = i // BATCH_SIZE + 1
        total_batches = (len(words) + BATCH_SIZE - 1) // BATCH_SIZE
        print(f"[{n}/{total_batches}] {batch[0]['word']} … {batch[-1]['word']}")

        good, bad = st.filter_valid(ask(model, batch), batch)

        # 단어가 안 들어간 문장은 그 단어들만 모아 한 번 더
        if bad:
            retry_items = [w for w in batch if w["word"] in {b["word"] for b in bad}]
            print(f"    검증 실패 {len(bad)}개 → 재요청")
            time.sleep(BATCH_PAUSE)
            more_good, still_bad = st.filter_valid(ask(model, retry_items, stricter=True), retry_items)
            good += more_good
            rejected_total += len(still_bad)
            for b in still_bad:
                print(f"      포기: {b['word']} :: {b['sentence'][:60]}")

        if good:
            st.save_sentences(good, args.db)
            saved += len(good)
        print(f"    저장 {len(good)}개 (누적 {saved}/{len(words)})")
        time.sleep(BATCH_PAUSE)

    after = st.coverage(args.db)
    print(f"\n완료: {saved}개 저장, {rejected_total}개 포기, {time.time() - started:.0f}초")
    print(f"최종 커버리지: 문맥 사용가능 {after['context_usable']}/{after['total']} "
          f"({after['context_usable'] / after['total'] * 100:.1f}%)  "
          f"[{before['context_usable']} → {after['context_usable']}]")


if __name__ == "__main__":
    main()
