#!/usr/bin/env python3
"""예문 생성 스크립트들이 공유하는 도구.

가장 중요한 건 `locate_word()` 다. 판정 자체는 context_blanker 모듈이
하고(= 앱의 Services/ContextBlanker.swift), 여기서는 그걸 불러 쓴다.

왜 필요한가: Context Mode 는 예문에서 단어를 찾아 빈칸으로 바꿔야 문제가
된다. 단어를 못 찾으면 그 예문은 의미 문제용 참고 자료일 뿐 문맥 문제로
쓰이지 못한다. 모델이 "harass" 를 달라고 했는데 "harassment" 가 든 문장을
주는 일이 실제로 흔해서, 저장 전에 같은 규칙으로 걸러낸다.
"""
import os
import re
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import context_blanker as cb

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DB = os.path.join(REPO_ROOT, "Database", "v85_20260312T133124Z.db")
UNIFIED_VOCAB_ID = "unified-teps-vocab-id"


def locate_word(sentence, target):
    """예문 안에서 대상 단어를 찾으면 True. 앱의 빈칸 처리와 같은 판정."""
    return cb.contains(target, sentence)


# ------------------------------------------------------------------- DB 도구
def connect(db_path=None):
    return sqlite3.connect(db_path or DEFAULT_DB)


def fetch_words_needing_sentences(db_path=None, limit=None):
    """예문이 없거나, 있어도 단어를 찾을 수 없어 Context Mode 에 못 쓰는 단어."""
    conn = connect(db_path)
    rows = conn.execute(
        """SELECT id, word, meaning, pos, exampleSentence
             FROM Corpus
            WHERE vocabularyId = ? AND isDeleted = 0
            ORDER BY datetime(createdAt) ASC;""",
        (UNIFIED_VOCAB_ID,),
    ).fetchall()
    conn.close()

    out = []
    for cid, word, meaning, pos, sentence in rows:
        if sentence and sentence.strip() and locate_word(sentence, word):
            continue
        out.append({"id": cid, "word": word, "meaning": meaning,
                    "pos": pos, "existing": sentence})
        if limit and len(out) >= limit:
            break
    return out


def save_sentences(updates, db_path=None):
    conn = connect(db_path)
    conn.executemany(
        """UPDATE Corpus
              SET exampleSentence = ?, updatedAt = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = ?;""",
        [(u["sentence"], u["id"]) for u in updates],
    )
    conn.commit()
    conn.close()


def coverage(db_path=None):
    """활성 단어 중 몇 개가 Context Mode 에 실제로 쓸 수 있는지."""
    conn = connect(db_path)
    rows = conn.execute(
        """SELECT word, exampleSentence FROM Corpus
            WHERE vocabularyId = ? AND isDeleted = 0;""",
        (UNIFIED_VOCAB_ID,),
    ).fetchall()
    conn.close()
    total = len(rows)
    has = sum(1 for w, s in rows if s and s.strip())
    usable = sum(1 for w, s in rows if s and s.strip() and locate_word(s, w))
    return {"total": total, "has_sentence": has, "context_usable": usable}


def build_prompt(batch, json_hint=True, style="api"):
    """품사까지 넘겨서 엉뚱한 품사의 문장이 나오지 않게 한다.

    json_hint=False 는 응답 스키마(구조화 출력)를 쓰는 호출용이다. 그때는
    형식을 스키마가 강제하므로 프롬프트에서 또 지시하면 서로 어긋난다.

    style="local" 은 LM Studio 등 로컬 소형 모델용이다. 규칙을 줄이고
    예시를 붙인다 — 소형 모델은 긴 규칙 목록보다 보기 두 개에 훨씬 잘
    따라온다.
    """
    if style == "local":
        return _build_local_prompt(batch, json_hint)
    lines = []
    for item in batch:
        pos = f" [{item['pos']}]" if item.get("pos") else ""
        lines.append(f"- {item['word']}{pos} ({item['meaning']})")
    word_list = "\n".join(lines)

    tail = ('\nRespond with ONLY a raw JSON array, no markdown fence, no commentary:\n'
            '[{"word": "...", "sentence": "..."}]\n') if json_hint else ""

    return f"""You are a TEPS vocabulary expert writing example sentences for a study app.

For each target word below, write exactly ONE natural English sentence that shows
the word used in an academic, business, or news register typical of TEPS.

Hard requirements:
1. The sentence MUST contain the target word itself. An inflected form is fine
   (commute -> commuting, plan -> planned), but a derived form is NOT
   (harass -> harassment is WRONG, it must contain "harass"/"harassed"/...).
2. Use the part of speech given in brackets, and the meaning given in parentheses.
3. For multi-word entries, keep the words together in order. A "~" marks a slot
   where an object goes (take ~ back -> "take the faulty laptop back").
4. 10-25 words, one sentence, no quotation marks around it.

Target words:
{word_list}
{tail}"""


def _build_local_prompt(batch, json_hint=True):
    """로컬 소형 모델용 프롬프트.

    큰 모델용과 세 가지가 다르다.
      - 규칙이 모두 한 줄이다
      - 통과/탈락 예시를 보여준다 (소형 모델에 가장 잘 듣는 장치)
      - 구(phrase) 는 첫 단어만 활용된다고 못박는다. 앱의 ContextBlanker 는
        머리 단어에만 굴절형을 허용하므로, "side effect" 를 달라고 했는데
        "side effects" 가 든 문장을 주면 빈칸을 못 만든다. 측정해 보면
        실패 예문의 대부분이 이 경우다.
    """
    lines = []
    for item in batch:
        pos = f" [{item['pos']}]" if item.get("pos") else ""
        lines.append(f"- {item['word']}{pos} = {item['meaning']}")
    word_list = "\n".join(lines)

    tail = ('\nOutput ONLY the JSON array. No explanation, no markdown fence.\n'
            if json_hint else "")

    return f"""Write one English example sentence for each vocabulary word.

RULES
1. The sentence must contain the word itself, spelled as given. You may add
   -s, -ed, or -ing to it. Do NOT swap in a different word built from it.
2. If the entry is a phrase, keep every word after the first exactly as given.
3. 10 to 20 words. Academic, business, or news style.
4. Match the part of speech in [brackets] and the Korean meaning after "=".

GOOD   abate       -> The storm began to abate shortly after midnight.
GOOD   scrutinize  -> Auditors will scrutinize every transaction from the final quarter.
BAD    legitimate  -> They confirmed the legitimacy of the results.  (legitimacy is another word)
BAD    side effect -> Patients should watch for side effects.        (must stay "side effect")

WORDS
{word_list}

Return a JSON array, one object per word, same order:
[{{"word": "abate", "sentence": "..."}}]
{tail}"""


def filter_valid(results, batch):
    """모델 응답에서 단어를 실제로 포함한 문장만 통과시킨다."""
    by_word = {item["word"].lower().strip(): item for item in batch}
    good, bad = [], []
    for res in results:
        key = (res.get("word") or "").lower().strip()
        sentence = (res.get("sentence") or "").strip()
        item = by_word.get(key)
        if not item or not sentence:
            continue
        if locate_word(sentence, item["word"]):
            good.append({"id": item["id"], "word": item["word"], "sentence": sentence})
        else:
            bad.append({"word": item["word"], "sentence": sentence})
    return good, bad
