#!/usr/bin/env python3
"""Claude 로 예문을 생성해 DB 에 채운다. (Gemini 판과 같은 일을 하는 대안)

Gemini 판과 다른 점은 구조화 출력을 쓴다는 것뿐이다. 응답 스키마를 모델에
강제하므로 마크다운 펜스를 벗겨내거나 JSON 파싱 실패를 처리할 필요가 없다.

사용법:
    export ANTHROPIC_API_KEY=...
    python3 Scripts/generate_sentences.py              # 전체
    python3 Scripts/generate_sentences.py --limit 40   # 맛보기
    python3 Scripts/generate_sentences.py --model claude-haiku-5-5
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sentence_tools as st

try:
    import anthropic
    from pydantic import BaseModel
except ImportError:
    print("필요한 패키지가 없습니다.  pip install anthropic pydantic")
    anthropic = None

DEFAULT_MODEL = "claude-opus-5-5"
BATCH_SIZE = 40


if anthropic:
    class SentenceItem(BaseModel):
        word: str
        sentence: str

    class SentenceBatch(BaseModel):
        items: list[SentenceItem]


def ask(client, model, batch, stricter=False):
    prompt = st.build_prompt(batch, json_hint=False)
    if stricter:
        prompt += ("\nThe previous attempt failed because the sentences did not contain "
                   "the target word itself. Write the target word literally, exactly as "
                   "given (an inflected form of that same word is acceptable).\n")

    for attempt in range(4):
        try:
            response = client.messages.parse(
                model=model,
                max_tokens=16000,
                messages=[{"role": "user", "content": prompt}],
                output_format=SentenceBatch,
            )
            parsed = response.parsed_output
            return [{"word": i.word, "sentence": i.sentence} for i in parsed.items]
        except anthropic.RateLimitError:
            wait = 10 * (attempt + 1)
            print(f"    요청 한도 초과 — {wait}초 대기")
            time.sleep(wait)
        except anthropic.APIStatusError as exc:
            print(f"    API 오류 {exc.status_code}: {exc}")
            if exc.status_code < 500:
                return []
            time.sleep(5 * (attempt + 1))
        except anthropic.APIConnectionError as exc:
            print(f"    연결 실패: {exc}")
            time.sleep(5 * (attempt + 1))
    return []


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=st.DEFAULT_DB)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    before = st.coverage(args.db)
    print(f"DB: {args.db}")
    print(f"시작 커버리지: 활성 {before['total']} / 예문 {before['has_sentence']} / "
          f"문맥 사용가능 {before['context_usable']} "
          f"({before['context_usable'] / before['total'] * 100:.1f}%)")

    words = st.fetch_words_needing_sentences(args.db, args.limit)
    print(f"생성 대상: {len(words)}개")
    if args.dry_run or not words or not anthropic:
        return

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("ANTHROPIC_API_KEY 가 설정되지 않았습니다.")
        return

    client = anthropic.Anthropic()
    saved, rejected_total = 0, 0
    started = time.time()

    for i in range(0, len(words), BATCH_SIZE):
        batch = words[i:i + BATCH_SIZE]
        n = i // BATCH_SIZE + 1
        total_batches = (len(words) + BATCH_SIZE - 1) // BATCH_SIZE
        print(f"[{n}/{total_batches}] {batch[0]['word']} … {batch[-1]['word']}")

        good, bad = st.filter_valid(ask(client, args.model, batch), batch)

        if bad:
            retry_items = [w for w in batch if w["word"] in {b["word"] for b in bad}]
            print(f"    검증 실패 {len(bad)}개 → 재요청")
            more_good, still_bad = st.filter_valid(
                ask(client, args.model, retry_items, stricter=True), retry_items)
            good += more_good
            rejected_total += len(still_bad)
            for b in still_bad:
                print(f"      포기: {b['word']} :: {b['sentence'][:60]}")

        if good:
            st.save_sentences(good, args.db)
            saved += len(good)
        print(f"    저장 {len(good)}개 (누적 {saved}/{len(words)})")

    after = st.coverage(args.db)
    print(f"\n완료: {saved}개 저장, {rejected_total}개 포기, {time.time() - started:.0f}초")
    print(f"최종 커버리지: 문맥 사용가능 {after['context_usable']}/{after['total']} "
          f"({after['context_usable'] / after['total'] * 100:.1f}%)  "
          f"[{before['context_usable']} → {after['context_usable']}]")


if __name__ == "__main__":
    main()
