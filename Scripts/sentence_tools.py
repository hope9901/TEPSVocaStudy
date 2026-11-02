#!/usr/bin/env python3
"""예문 생성 스크립트들이 공유하는 도구.

가장 중요한 건 `locate_word()` 다. 이건 앱의
Services/ContextSentenceBuilder.swift 를 그대로 옮긴 것으로, 생성된 예문
안에서 대상 단어를 찾을 수 있는지 판정한다.

왜 필요한가: Context Mode 는 예문에서 단어를 찾아 빈칸으로 바꿔야 문제가
된다. 단어를 못 찾으면 그 예문은 의미 문제용 참고 자료일 뿐 문맥 문제로
쓰이지 못한다. 모델이 "harass" 를 달라고 했는데 "harassment" 가 든 문장을
주는 일이 실제로 흔해서, 저장 전에 같은 규칙으로 걸러낸다.
"""
import os
import re
import sqlite3

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DB = os.path.join(REPO_ROOT, "Database", "v85_20260312T133124Z.db")
UNIFIED_VOCAB_ID = "unified-teps-vocab-id"

# ---------------------------------------------------------------- 굴절 처리
VOWELS = set("aeiou")

IRREGULARS = {
    "be": {"am", "is", "are", "was", "were", "been", "being"},
    "have": {"has", "had", "having"},
    "do": {"does", "did", "done", "doing"},
    "go": {"goes", "went", "gone", "going"},
    "get": {"gets", "got", "gotten", "getting"},
    "take": {"takes", "took", "taken", "taking"},
    "make": {"makes", "made", "making"},
    "give": {"gives", "gave", "given", "giving"},
    "come": {"comes", "came", "coming"},
    "see": {"sees", "saw", "seen", "seeing"},
    "know": {"knows", "knew", "known", "knowing"},
    "think": {"thinks", "thought", "thinking"},
    "say": {"says", "said", "saying"},
    "put": {"puts", "putting"},
    "keep": {"keeps", "kept", "keeping"},
    "hold": {"holds", "held", "holding"},
    "run": {"runs", "ran", "running"},
    "bring": {"brings", "brought", "bringing"},
    "stand": {"stands", "stood", "standing"},
    "fall": {"falls", "fell", "fallen", "falling"},
    "break": {"breaks", "broke", "broken", "breaking"},
    "leave": {"leaves", "left", "leaving"},
    "lose": {"loses", "lost", "losing"},
    "pay": {"pays", "paid", "paying"},
    "draw": {"draws", "drew", "drawn", "drawing"},
    "blow": {"blows", "blew", "blown", "blowing"},
    "wear": {"wears", "wore", "worn", "wearing"},
    "sit": {"sits", "sat", "sitting"},
    "speak": {"speaks", "spoke", "spoken", "speaking"},
    "write": {"writes", "wrote", "written", "writing"},
    "cut": {"cuts", "cutting"},
    "let": {"lets", "letting"},
    "set": {"sets", "setting"},
    "catch": {"catches", "caught", "catching"},
    "feel": {"feels", "felt", "feeling"},
    "find": {"finds", "found", "finding"},
    "tell": {"tells", "told", "telling"},
    "man": {"men"},
    "woman": {"women"},
    "child": {"children"},
    "person": {"people"},
    "foot": {"feet"},
    "tooth": {"teeth"},
}

PLACEHOLDER_TOKENS = {
    "~", "one's", "ones", "oneself", "someone", "somebody", "something",
    "sb", "sth", "one",
}


def surface_forms(word):
    """EnglishInflector.surfaceForms(of:) 와 같은 규칙."""
    base = word.lower().replace("’", "'")
    forms = {base}
    if len(base) < 2 or not all(c.isalpha() or c == "'" for c in base):
        return forms

    forms |= IRREGULARS.get(base, set())

    chars = list(base)
    last = chars[-1]
    second = chars[-2] if len(chars) >= 2 else None
    stem = base[:-1]

    if base.endswith(("s", "x", "z", "ch", "sh", "o")):
        forms.add(base + "es")
    elif last == "y" and second and second not in VOWELS:
        forms.add(stem + "ies")
    else:
        forms.add(base + "s")

    if last == "e":
        forms.add(base + "d")
        forms.add(stem + "ing")
        forms.add(base + "s")
    elif last == "y" and second and second not in VOWELS:
        forms.add(stem + "ied")
        forms.add(base + "ing")
    else:
        forms.add(base + "ed")
        forms.add(base + "ing")
        if base.endswith("c"):
            forms.add(base + "ked")
            forms.add(base + "king")
        if (len(chars) >= 3 and second in VOWELS and last not in VOWELS
                and last not in "wxy" and chars[-3] not in VOWELS):
            forms.add(base + last + "ed")
            forms.add(base + last + "ing")

    if base.endswith("is"):
        forms.add(base[:-2] + "es")

    return forms


# ---------------------------------------------------------------- 문장 매칭
def _tokenize(chars):
    tokens, i = [], 0
    while i < len(chars):
        if not (chars[i].isalpha() or chars[i] in ("'", "’")):
            i += 1
            continue
        start = i
        while i < len(chars) and (chars[i].isalpha() or chars[i] in ("'", "’")):
            i += 1
        raw = "".join(chars[start:i]).strip("'’")
        if raw:
            tokens.append((raw.lower().replace("’", "'"), start, i))
    return tokens


def _make_pattern(target):
    norm = target.lower().replace("’", "'").replace("~", " ~ ")
    elements = []
    for raw in norm.split():
        tok = "".join(c for c in raw if c.isalpha() or c in "'~")
        if not tok:
            continue
        if tok in PLACEHOLDER_TOKENS:
            elements.append(("wild", 0, 3))
        else:
            elements.append(("word", surface_forms(tok)))
    return elements if any(e[0] == "word" for e in elements) else []


def _match(pattern, pi, tokens, ti):
    if pi >= len(pattern):
        return ti
    if ti > len(tokens):
        return None
    kind = pattern[pi][0]
    if kind == "word":
        if ti < len(tokens) and tokens[ti][0] in pattern[pi][1]:
            return _match(pattern, pi + 1, tokens, ti + 1)
        return None
    low, high = pattern[pi][1], pattern[pi][2]
    for consumed in range(low, high + 1):
        nxt = ti + consumed
        if nxt > len(tokens):
            break
        end = _match(pattern, pi + 1, tokens, nxt)
        if end is not None:
            return end
    return None


def locate_word(sentence, target):
    """예문 안에서 대상 단어를 찾으면 True. 앱의 빈칸 처리와 같은 판정."""
    if not sentence or not sentence.strip() or not target.strip():
        return False
    chars = list(sentence.strip())
    tokens = _tokenize(chars)
    if not tokens:
        return False
    pattern = _make_pattern(target.strip())
    if not pattern:
        return False
    for start in range(len(tokens)):
        end = _match(pattern, 0, tokens, start)
        if end is not None and end > start:
            return True
    return False


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


def build_prompt(batch, json_hint=True):
    """품사까지 넘겨서 엉뚱한 품사의 문장이 나오지 않게 한다.

    json_hint=False 는 응답 스키마(구조화 출력)를 쓰는 호출용이다. 그때는
    형식을 스키마가 강제하므로 프롬프트에서 또 지시하면 서로 어긋난다.
    """
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
