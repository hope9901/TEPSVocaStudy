#!/usr/bin/env python3
"""LM Studio 로컬 서버로 예문을 생성해 DB 에 채운다.

LM Studio 의 OpenAI 호환 엔드포인트(기본 http://localhost:1234/v1)에 직접
요청한다. 표준 라이브러리만 쓰므로 pip 설치가 필요 없고, API 키도 네트워크도
필요 없다.

준비
    LM Studio 실행 → 모델 로드 → Developer 탭에서 "Start Server"

사용법
    python3 Scripts/generate_sentences_lmstudio.py --limit 20     # 맛보기
    python3 Scripts/generate_sentences_lmstudio.py                # 전체
    python3 Scripts/generate_sentences_lmstudio.py --batch-size 10 --model <id>

중단해도 안전하다. 이미 저장된 단어는 다음 실행에서 대상에서 빠진다.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sentence_tools as st

DEFAULT_URL = "http://localhost:1234/v1"
# 소형 모델은 목록이 길어지면 뒤쪽 단어를 빠뜨리거나 지어낸다. 15개가 안전선.
DEFAULT_BATCH = 15


def post(url, payload, timeout=300):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def pick_model(base_url, requested):
    """지정이 없으면 현재 로드된 첫 모델을 쓴다."""
    if requested:
        return requested
    try:
        with urllib.request.urlopen(f"{base_url}/models", timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        models = [m["id"] for m in data.get("data", [])]
        if models:
            print(f"로드된 모델: {', '.join(models)}")
            return models[0]
    except Exception as exc:                                   # noqa: BLE001
        print(f"모델 목록을 못 읽었습니다: {exc}")
    return "local-model"


def extract_json_array(text):
    """소형 모델은 JSON 앞뒤에 말을 붙이거나 펜스를 씌운다. 배열만 끄집어낸다."""
    text = text.strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if fence:
        text = fence.group(1).strip()
    start, end = text.find("["), text.rfind("]")
    if start == -1 or end == -1 or end < start:
        return []
    try:
        parsed = json.loads(text[start:end + 1])
    except json.JSONDecodeError:
        return []
    return parsed if isinstance(parsed, list) else []


def ask(base_url, model, batch, temperature, stricter=False):
    prompt = st.build_prompt(batch, style="local")
    if stricter:
        prompt += ("\nThe last attempt failed: the sentence did not contain the word "
                   "itself. Write the word exactly as given, or with -s/-ed/-ing.\n")

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": temperature,
        "max_tokens": 2048,
    }
    try:
        data = post(f"{base_url}/chat/completions", payload)
        return extract_json_array(data["choices"][0]["message"]["content"])
    except urllib.error.URLError as exc:
        print(f"    LM Studio 에 연결할 수 없습니다: {exc}")
        print(f"    서버가 {base_url} 에서 돌고 있는지 확인하세요.")
        return None                                  # None = 치명적, 중단
    except (KeyError, json.JSONDecodeError) as exc:
        print(f"    응답 해석 실패: {exc}")
        return []


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=st.DEFAULT_DB)
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--model", default=None)
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH)
    parser.add_argument("--temperature", type=float, default=0.4)
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--export-prompt", type=int, metavar="N",
                        help="서버를 쓰지 않고, 다음 N개 단어용 프롬프트만 출력한다. "
                             "LM Studio 채팅창에 직접 붙여넣을 때 쓴다.")
    args = parser.parse_args()

    if args.export_prompt:
        words = st.fetch_words_needing_sentences(args.db, args.export_prompt)
        print(st.build_prompt(words, style="local"))
        return

    before = st.coverage(args.db)
    print(f"DB: {args.db}")
    print(f"시작: 활성 {before['total']} / 문맥 사용가능 {before['context_usable']} "
          f"({before['context_usable'] / before['total'] * 100:.1f}%)")

    words = st.fetch_words_needing_sentences(args.db, args.limit)
    print(f"생성 대상: {len(words)}개")
    if args.dry_run or not words:
        return

    model = pick_model(args.url, args.model)
    print(f"사용 모델: {model}\n")

    saved, given_up = 0, []
    started = time.time()
    size = max(1, args.batch_size)

    for i in range(0, len(words), size):
        batch = words[i:i + size]
        n, total = i // size + 1, (len(words) + size - 1) // size
        print(f"[{n}/{total}] {batch[0]['word']} … {batch[-1]['word']}")

        results = ask(args.url, model, batch, args.temperature)
        if results is None:
            print("중단합니다. 지금까지 저장된 내용은 DB 에 남아 있습니다.")
            break

        good, bad = st.filter_valid(results, batch)

        missing = {w["word"] for w in batch} - {g["word"] for g in good}
        if missing:
            retry = [w for w in batch if w["word"] in missing]
            print(f"    실패 {len(missing)}개 → 재요청")
            again = ask(args.url, model, retry, args.temperature, stricter=True)
            if again:
                more_good, _ = st.filter_valid(again, retry)
                good += more_good
                missing -= {g["word"] for g in more_good}
            given_up += sorted(missing)

        if good:
            st.save_sentences(good, args.db)
            saved += len(good)
        print(f"    저장 {len(good)}/{len(batch)}  (누적 {saved})")

    after = st.coverage(args.db)
    print(f"\n완료: {saved}개 저장, 포기 {len(given_up)}개, {time.time() - started:.0f}초")
    if given_up:
        print("포기한 단어 (다시 실행하면 재시도합니다):")
        print("  " + ", ".join(given_up[:40]) + (" …" if len(given_up) > 40 else ""))
    print(f"최종: 문맥 사용가능 {after['context_usable']}/{after['total']} "
          f"({after['context_usable'] / after['total'] * 100:.1f}%)  "
          f"[{before['context_usable']} → {after['context_usable']}]")


if __name__ == "__main__":
    main()
