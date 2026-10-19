#!/usr/bin/env python3
"""The texts ADIF Lint can show in another language, from its sources, and the state of each
language's table (data/lang/<code>.json).

    tools/extract_strings.py                 a summary per language
    tools/extract_strings.py --keys          every key, one per line (JSON strings)
    tools/extract_strings.py --missing fr    the keys the French table lacks, as JSON to fill in
    tools/extract_strings.py --check         exit 1 when a table is malformed: a key no source
                                             has (stale), placeholders that differ, a plural
                                             without its forms (the lang_check test runs this)

A key is the English text. Found: T/TF/TP and N in the plugin (Objective-C literals), tr/trf/
trp and N_ in the core (C++ literals), the plugin helpers' literal arguments (ADIFLabel,
ADIFCheckbox, ADIFTextField, ADIFPopup items, addButton:, initWithTitle:, setStatus:, column
titles, smallButton, pullDown, sectionTitle, wrapping), the menu's names (setItem) and
plural(n, "word") ("{n} word|{n} words").
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OBJC = r'@"((?:[^"\\\n]|\\.)*)"'
OBJC_SEQ = r'(@"(?:[^"\\\n]|\\.)*"(?:\s*@"(?:[^"\\\n]|\\.)*")*)'
CPP = r'"((?:[^"\\\n]|\\.)*)"'
CPP_SEQ = r'((?<![@\w])"(?:[^"\\\n]|\\.)*"(?:\s*"(?:[^"\\\n]|\\.)*")*)'


def unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == '\\' and i + 1 < len(s):
            e = s[i + 1]
            if e in 'uU':
                n = 4 if e == 'u' else 8
                digits = s[i + 2:i + 2 + n]
                if len(digits) == n and all(d in '0123456789abcdefABCDEF' for d in digits):
                    out.append(chr(int(digits, 16)))
                    i += 2 + n
                    continue
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\', "'": "'", '0': '\0'}.get(e, '\\' + e))
            i += 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def joined(seq, objc):
    return ''.join(unescape(m) for m in re.findall(OBJC if objc else CPP, seq))


def strip_comments(src):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif c == "'":
            j = i + 1
            while j < n and src[j] != "'":
                j += 2 if src[j] == '\\' else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def arguments(src, at, count):
    """The first `count` arguments of the call whose '(' is at src[at], as source text."""
    out, depth, i, start, n = [], 0, at + 1, at + 1, len(src)
    while i < n and len(out) < count:
        c = src[i]
        if c == '"':
            i += 1
            while i < n and src[i] != '"':
                i += 2 if src[i] == '\\' else 1
        elif c == "'":
            i += 1
            while i < n and src[i] != "'":
                i += 2 if src[i] == '\\' else 1
        elif c in '([{':
            depth += 1
        elif c in ')]}':
            if depth == 0:
                out.append(src[start:i])
                break
            depth -= 1
        elif c == ',' and depth == 0:
            out.append(src[start:i])
            start = i + 1
        i += 1
    return out


def literals(arg, objc):
    """The texts in one argument: each run of adjacent literals (both sides of a ?: too)."""
    return [joined(m.group(1), objc) for m in re.finditer(OBJC_SEQ if objc else CPP_SEQ, arg)]


def keys():
    found = {}  # key -> first place

    def add(key, where):
        if key and re.search(r'[A-Za-z]', key) and key not in found:
            found[key] = where

    for path in sorted(glob.glob(os.path.join(ROOT, 'src/plugin/*.mm')) + glob.glob(os.path.join(ROOT, 'src/plugin/*.h'))):
        rel = os.path.relpath(path, ROOT)
        src = strip_comments(open(path, encoding='utf-8').read())
        # T(@"...") TF(@"..." N(@"...") and the helpers' first literal
        for fn in [r'\bT', r'\bTF', r'\bN', r'ADIFLabel', r'ADIFCheckbox', r'ADIFTextField', r'smallButton', r'pullDown', r'sectionTitle',
                   r'wrapping', r'chooseOpen', r'rowItem']:
            for m in re.finditer(fn + r'\(', src):
                for a in arguments(src, m.end() - 1, 1):
                    for t in literals(a, True):
                        add(t, rel)
        for m in re.finditer(r'\bTP\(\s*' + OBJC_SEQ + r'\s*,\s*' + OBJC_SEQ, src):
            add(joined(m.group(1), True) + '|' + joined(m.group(2), True), rel)
        # smallButton(@"Title", @"tip", ...) and pullDown(@"Title", @"tip"): the second too
        for m in re.finditer(r'(?:smallButton|pullDown)\(\s*' + OBJC_SEQ + r'\s*,\s*' + OBJC_SEQ, src):
            add(joined(m.group(2), True), rel)
        for m in re.finditer(r'(?<![\w:])setStatus\(\s*' + CPP_SEQ, src):  # the Map's own status line
            add(joined(m.group(1), False), rel)
        for m in re.finditer(r'\bmenuItem\(\s*\w+\s*,\s*' + OBJC_SEQ, src):  # the Map's menus
            add(joined(m.group(1), True), rel)
        for m in re.finditer(r'setSummary:\s*' + CPP_SEQ, src):  # New QSO's summary line
            add(joined(m.group(1), False), rel)
        for sel in ['addButton:', 'initWithTitle:', 'setStatus:', 'setHeadline:', 'setStationStatus:', 'setMapDetailState:',
                    'setCountryStatus:', r'setLotwUsersOn:\s*\w+\s*status:', 'setPotaStatus:', 'setIotaStatus:', 'setAccount:', 'setCredit:']:
            for m in re.finditer(sel + r'\s*(?:\w+\s*\?\s*)?' + OBJC_SEQ, src):
                add(joined(m.group(1), True), rel)
        for m in re.finditer(r'ADIFPopup\(\s*@\[(.*?)\]\s*\)', src, re.S):
            for item in re.finditer(OBJC_SEQ, m.group(1)):
                add(joined(item.group(1), True), rel)
        # Column titles: {"ident", "Title", width} in ADIFToolColumn lists
        for m in re.finditer(r'\{\s*"[A-Za-z0-9_.:-]*"\s*,\s*' + CPP_SEQ + r'\s*,\s*\d+\s*\}', src):
            add(joined(m.group(1), False), rel)
        for m in re.finditer(r'setItem\(\s*kCmd\w+\s*,\s*' + CPP_SEQ, src):
            add(joined(m.group(1), False), rel)
        for m in re.finditer(r'\bplural\(\s*[^,()]+(?:\([^()]*\))?[^,()]*,\s*' + CPP_SEQ + r'\s*\)', src):
            w = joined(m.group(1), False)
            add('{n} ' + w + '|{n} ' + w + 's', rel)
        for fn in [r'\btr', r'\btrf', r'\bN_']:
            for m in re.finditer(fn + r'\(', src):
                for a in arguments(src, m.end() - 1, 1):
                    for t in literals(a, False):
                        add(t, rel)
        for m in re.finditer(r'\btrp\(\s*' + CPP_SEQ + r'\s*,\s*' + CPP_SEQ, src):
            add(joined(m.group(1), False) + '|' + joined(m.group(2), False), rel)
    for path in sorted(glob.glob(os.path.join(ROOT, 'src/core/*.cpp'))):
        rel = os.path.relpath(path, ROOT)
        src = strip_comments(open(path, encoding='utf-8').read())
        for fn in [r'\btr', r'\btrf', r'\bN_']:
            for m in re.finditer(fn + r'\(', src):
                for a in arguments(src, m.end() - 1, 1):
                    for t in literals(a, False):
                        add(t, rel)
        for m in re.finditer(r'\btrp\(\s*' + CPP_SEQ + r'\s*,\s*' + CPP_SEQ, src):
            add(joined(m.group(1), False) + '|' + joined(m.group(2), False), rel)
    return found


PRINTF = re.compile(r'%(\d+\$)?[-+ #0\']*[\d*]*(?:\.[\d*]+)?(?:hh|h|ll|l|z|j|t|L|q)?([@diouxXeEfFgGcsp])')


def printf_order_ok(key, text):
    """printf fills its arguments in order: a translation keeps the key's order, or numbers
    every one (%2$@ %1$ld) to move them."""
    want = [m.group(0) for m in PRINTF.finditer(key.split('##')[0])]
    got = list(PRINTF.finditer(text))
    if got and all(m.group(1) for m in got):
        return sorted(re.sub(r'^%\d+\$', '%', m.group(0)) for m in got) == sorted(want)
    return [m.group(0) for m in got] == want


def placeholders(text):
    text = text.split('##')[0]  # a key's context isn't text
    out = re.findall(r'\{[A-Za-z0-9_]+\}', text)
    for m in re.finditer(r'%(?:\d+\$)?[-+ #0\']*[\d*]*(?:\.[\d*]+)?(?:hh|h|ll|l|z|j|t|L|q)?([@diouxXeEfFgGcsp%])', text):
        if m.group(1) != '%':
            out.append(re.sub(r'^%\d+\$', '%', m.group(0)))
    return sorted(out)


PLURAL_FORMS = {'en': ['one', 'other'], 'de': ['one', 'other'], 'fr': ['one', 'other'], 'es': ['one', 'other'],
                'ko': ['other'], 'ja': ['other']}


def check_table(path, known):
    problems = []
    try:
        table = json.load(open(path, encoding='utf-8'))
    except Exception as e:
        return [f'{path}: not JSON: {e}'], 0
    code = table.get('meta', {}).get('language', '')
    strings = table.get('strings', {})
    if not code or not isinstance(strings, dict):
        return [f'{path}: needs meta.language and strings'], 0
    done = 0
    for key, value in strings.items():
        if key not in known:
            problems.append(f'{path}: stale (no source has it): {key!r}')
            continue
        if isinstance(value, dict):
            if '|' not in key:
                problems.append(f'{path}: plural forms for a text that is not a count: {key!r}')
                continue
            want = PLURAL_FORMS.get(code, ['one', 'other'])
            for form in want:
                if not value.get(form):
                    problems.append(f'{path}: {key!r} lacks its {form!r} form')
            one, other = key.split('|', 1)
            for form, text in value.items():
                if placeholders(text) != placeholders(other):
                    problems.append(f'{path}: placeholders differ in {key!r} ({form}): {text!r}')
                elif not printf_order_ok(other, text):
                    problems.append(f'{path}: printf placeholders out of order in {key!r} ({form}): {text!r}')
            done += 1
        elif isinstance(value, str):
            if '|' in key and key.count('{n}') == 2:
                problems.append(f'{path}: {key!r} is a count: give its forms')
                continue
            if value and placeholders(value) != placeholders(key):
                problems.append(f'{path}: placeholders differ: {key!r} -> {value!r}')
            elif value and not printf_order_ok(key, value):
                problems.append(f'{path}: printf placeholders out of order (number them all to move them): {key!r} -> {value!r}')
            if value:
                done += 1
        else:
            problems.append(f'{path}: {key!r}: not a string or forms')
    return problems, done


def pseudo(text):
    """Marked and about a third longer, placeholders kept: for finding text that isn't
    translated, and layouts too tight for longer languages."""
    accents = str.maketrans('aeiouAEIOUcnyCNY', 'àéîõüÀÉÎÕÜçñýÇÑÝ')
    parts = re.split(r'(\{[A-Za-z0-9_]+\}|%(?:\d+\$)?[-+ #0\']*[\d*]*(?:\.[\d*]+)?(?:hh|h|ll|l|z|j|t|L|q)?[@diouxXeEfFgGcsp%]|\n)', text)
    body = ''.join(p if (p.startswith('{') or p.startswith('%') or p == '\n') else p.translate(accents) for p in parts)
    letters = len(re.sub(r'[^A-Za-z]', '', text))
    return '⟦' + body + '·' * max(1, letters // 3) + '⟧'


def main():
    found = keys()
    args = sys.argv[1:]
    if '--pseudo' in args:
        out = args[args.index('--pseudo') + 1]
        strings = {}
        for k in found:
            if '|' in k and k.count('{n}') == 2:
                one, other = k.split('|', 1)
                strings[k] = {'one': pseudo(one), 'other': pseudo(other)}
            else:
                strings[k] = pseudo(k)
        json.dump({'meta': {'language': 'qps', 'name': 'Pseudo', 'note': 'test only'}, 'strings': strings}, open(out, 'w', encoding='utf-8'),
                  ensure_ascii=False, indent=0)
        print(f'{len(strings)} pseudo texts in {out}')
        return 0
    if '--keys' in args:
        for k in sorted(found):
            print(json.dumps(k, ensure_ascii=False))
        return 0
    if '--missing' in args:
        code = args[args.index('--missing') + 1]
        path = os.path.join(ROOT, 'data/lang', code + '.json')
        have = json.load(open(path, encoding='utf-8')).get('strings', {}) if os.path.exists(path) else {}
        miss = {k: ({'one': '', 'other': ''} if '|' in k and k.count('{n}') == 2 else '') for k in sorted(found) if k not in have}
        print(json.dumps(miss, ensure_ascii=False, indent=1))
        return 0
    bad = []
    for path in sorted(glob.glob(os.path.join(ROOT, 'data/lang/*.json'))):
        problems, done = check_table(path, found)
        bad += problems
        print(f'{os.path.basename(path)}: {done} of {len(found)} translated ({100 * done // max(1, len(found))}%), {len(problems)} problems')
    if not glob.glob(os.path.join(ROOT, 'data/lang/*.json')):
        print(f'{len(found)} texts; no tables yet')
    for p in bad[:60]:
        print(p)
    return 1 if ('--check' in args and bad) else 0


if __name__ == '__main__':
    sys.exit(main())
