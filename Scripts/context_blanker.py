#!/usr/bin/env python3
"""Services/ContextBlanker.swift 를 그대로 옮긴 것.

Context Mode 는 예문에서 표제어를 찾아 빈칸으로 바꿔야 문제가 된다. 단어를
못 찾으면 그 예문은 뜻 문제용 참고 자료일 뿐 문맥 문제로 쓰이지 못한다.
예문을 저장하기 전에 앱과 **똑같은 규칙**으로 걸러야 하므로, 판정 로직을
파이썬에서 다시 구현하지 않고 Swift 쪽을 그대로 옮긴다.

Swift 를 고치면 이 파일도 같이 고쳐야 한다. verify_blanker.py 가 두 구현이
어긋나지 않았는지 번들 DB 의 예문 전체로 확인한다.
"""
import re

BLANK = "______"

_APOSTROPHE = "['’]"
_GAP = r"(?:\s+[\w'’,\-]+){1,4}\s+"
_POSSESSIVE = r"(?:my|your|his|her|its|our|their|one['’]s|someone['’]s|[A-Za-z]+['’]s)"
_REFLEXIVE = (r"(?:myself|yourself|himself|herself|itself|ourselves|yourselves|"
              r"themselves|oneself)")
_PLACEHOLDERS = {"~", "someone", "somebody", "something", "sb", "sth", "a person",
                 "-ing"}

# 단어 목록에 실제로 나오는 불규칙 동사들 (Swift 쪽 irregularForms 와 동일)
IRREGULAR_FORMS = {
    "begin": ["began", "begun"], "come": ["came"], "go": ["went", "gone"],
    "take": ["took", "taken"], "give": ["gave", "given"], "get": ["got", "gotten"],
    "run": ["ran"], "make": ["made"], "bring": ["brought"], "hold": ["held"],
    "keep": ["kept"], "break": ["broke", "broken"], "fall": ["fell", "fallen"],
    "draw": ["drew", "drawn"], "see": ["saw", "seen"], "stand": ["stood"],
    "lay": ["laid"], "pay": ["paid"], "say": ["said"], "think": ["thought"],
    "buy": ["bought"], "catch": ["caught"], "teach": ["taught"], "seek": ["sought"],
    "fight": ["fought"], "find": ["found"], "leave": ["left"], "lose": ["lost"],
    "mean": ["meant"], "meet": ["met"], "send": ["sent"], "spend": ["spent"],
    "build": ["built"], "feel": ["felt"], "sell": ["sold"], "tell": ["told"],
    "win": ["won"], "write": ["wrote", "written"], "drive": ["drove", "driven"],
    "rise": ["rose", "risen"], "arise": ["arose", "arisen"], "speak": ["spoke", "spoken"],
    "choose": ["chose", "chosen"], "forget": ["forgot", "forgotten"],
    "undergo": ["underwent", "undergone"], "withdraw": ["withdrew", "withdrawn"],
    "overcome": ["overcame"], "foresee": ["foresaw", "foreseen"], "withhold": ["withheld"],
    "uphold": ["upheld"], "undertake": ["undertook", "undertaken"], "mislead": ["misled"],
    "lead": ["led"], "bear": ["bore", "borne"], "shake": ["shook", "shaken"],
    "strike": ["struck"], "stick": ["stuck"], "hang": ["hung"], "sink": ["sank", "sunk"],
    "shrink": ["shrank", "shrunk"], "blow": ["blew", "blown"], "grow": ["grew", "grown"],
    "throw": ["threw", "thrown"], "fly": ["flew", "flown"], "lie": ["lay", "lain", "lying"],
    "have": ["has", "had"], "do": ["did", "done", "does"], "undo": ["undid", "undone"],
    "sit": ["sat"], "shoot": ["shot"], "hide": ["hid", "hidden"], "ride": ["rode", "ridden"],
    "sweep": ["swept"], "deal": ["dealt"], "flee": ["fled"], "know": ["knew", "known"],
    "oversee": ["oversaw", "overseen"], "overthrow": ["overthrew", "overthrown"],
    "forgo": ["forwent", "forgone"], "forsake": ["forsook", "forsaken"],
    "befall": ["befell", "befallen"], "steal": ["stole", "stolen"], "strew": ["strewn"],
    "tie": ["tying"], "die": ["dying"], "bark": ["barked"], "put": ["put"], "set": ["set"],
    "cut": ["cut"], "let": ["let"], "cast": ["cast"], "spread": ["spread"], "shed": ["shed"],
}

_DOUBLING = re.compile(r"[^aeiou][aeiou][bdgklmnprt]$")
_ONES = re.compile(r"^one['’]s$")


def inflections(word):
    """규칙 변화 + 목록에 있는 불규칙 변화."""
    forms = {word, word + "s", word + "es", word + "ed", word + "d", word + "ing"}
    if word.endswith("e"):
        stem = word[:-1]
        forms |= {stem + "ing", stem + "ed"}
    if word.endswith("y"):
        stem = word[:-1]
        forms |= {stem + "ies", stem + "ied"}
    if _DOUBLING.search(word):
        forms |= {word + word[-1] + "ed", word + word[-1] + "ing"}
    if word.endswith("ic"):
        forms |= {word + "ked", word + "king"}
    forms |= set(IRREGULAR_FORMS.get(word, []))
    return forms


def _escaped(literal):
    """아포스트로피는 두 종류 모두 받아들이도록 문자 클래스로 바꾼다."""
    return _APOSTROPHE.join(re.escape(part) for part in re.split(r"['’]", literal))


def _token_pattern(token, is_head):
    lower = token.lower()
    if _ONES.match(lower):
        return _POSSESSIVE
    if lower == "oneself":
        return _REFLEXIVE
    if not is_head:
        return _escaped(lower)
    forms = sorted(inflections(lower), key=len, reverse=True)
    return "(?:" + "|".join(_escaped(f) for f in forms) + ")"


_cache = {}


def regex_for(word):
    if word in _cache:
        return _cache[word]

    tokens = word.strip().strip(".!?").split()
    # "be saddled with" → "I'm saddled with": 계사는 형태가 바뀌고 주어와
    # 붙어버리기도 하므로 나머지 구절만 맞춘다.
    if len(tokens) > 1 and tokens[0].lower() == "be":
        tokens = tokens[1:]
    if not tokens:
        _cache[word] = None
        return None

    runs = [[]]
    for index, token in enumerate(tokens):
        lower = token.lower()
        is_placeholder = (lower in _PLACEHOLDERS
                          or (len(token) == 1 and token.upper() == token
                              and token != "I" and len(tokens) > 1))
        if is_placeholder:
            if runs[-1]:
                runs.append([])
            continue
        runs[-1].append(_token_pattern(token, is_head=index == 0))
    runs = [r for r in runs if r]
    if not runs:
        _cache[word] = None
        return None

    body = _GAP.join("(" + r"\s+".join(r) + ")" for r in runs)
    pattern = r"(?<![\w'’])" + body + r"(?![\w])"
    try:
        compiled = re.compile(pattern, re.IGNORECASE)
    except re.error:
        compiled = None
    _cache[word] = compiled
    return compiled


def contains(word, sentence):
    """예문 안에서 표제어를 찾을 수 있으면 True."""
    if not word or not sentence:
        return False
    rx = regex_for(word)
    return bool(rx and rx.search(sentence))


def blanked(word, sentence):
    """앱이 보여줄 빈칸 문장. 못 만들면 None."""
    if not word or not sentence:
        return None
    rx = regex_for(word)
    if not rx:
        return None
    spans = []
    for match in rx.finditer(sentence):
        for group in range(1, (match.re.groups or 0) + 1):
            span = match.span(group)
            if span[0] != -1 and span[1] > span[0]:
                spans.append(span)
    if not spans:
        return None
    result = sentence
    for start, end in sorted(spans, key=lambda s: s[0], reverse=True):
        result = result[:start] + BLANK + result[end:]
    return result
