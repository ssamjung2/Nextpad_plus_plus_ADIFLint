#!/usr/bin/env python3
"""Builds data/lang/<code>.json from translation batches, keeping what the tables already have.

    tools/merge_translations.py KEYS.json BATCH.txt...

KEYS.json is the list of keys the batches number (a snapshot of extract_strings.py --keys, so
the numbers stay put while the sources change). A batch is plain text, an entry per key:

    60
    ko (유효한 날짜가 없는 QSO {n}건)
    fr ({n} QSO sans date valide) ‖ ({n} QSO sans date valide)
    de ...

the number, then a line per language: its code, a space, the text. "=" is the English unchanged;
"\\n" is a line break. A count (a key "one|other") takes its forms joined by " ‖ ", one first;
one text serves every form (Korean and Japanese have only "other"). A text gets the English's
leading and trailing spaces when its line has none of its own. French gets a no-break space before : ; ? ! and
inside « », as French typography wants.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGS = {
    'ko': '한국어',
    'fr': 'Français',
    'de': 'Deutsch',
    'es': 'Español',
    'ja': '日本語',
}
NOTE = ('Drafted by Claude (an AI, Anthropic) in October 2026 from the English texts; not yet reviewed by a native '
        'speaker. Corrections are welcome: each key is the English text, each value its translation.')
FORMS = {'ko': ['other'], 'ja': ['other'], 'fr': ['one', 'other'], 'de': ['one', 'other'], 'es': ['one', 'other']}


def is_count(key):
    return '|' in key and key.count('{n}') == 2


def english(key):
    return key.split('##')[0]


def edges(key, text):
    """The English's leading and trailing spaces, when the translation's line lacks them (a
    line may also start with a space of its own: German " oder" for ", or ")."""
    e = english(key)
    lead = e[:len(e) - len(e.lstrip(' '))]
    trail = e[len(e.rstrip(' ')):]
    if lead and not text.startswith(' '):
        text = lead + text
    if trail and not text.endswith(' '):
        text = text + trail
    return text


def french(text):
    text = re.sub(r' ([:;?!])', ' \\1', text)
    text = text.replace('« ', '« ').replace(' »', ' »')
    return text


def parse(path):
    entries, cur = {}, None
    for n, line in enumerate(open(path, encoding='utf-8').read().split('\n'), 1):
        if not line.strip():
            continue
        if re.fullmatch(r'\d+', line.strip()):
            cur = int(line.strip())
            if cur in entries:
                sys.exit(f'{path}:{n}: entry {cur} twice')
            entries[cur] = {}
            continue
        code, _, text = line.partition(' ')
        if cur is None or code not in LANGS:
            sys.exit(f'{path}:{n}: expected a number or "<code> <text>": {line!r}')
        if code in entries[cur]:
            sys.exit(f'{path}:{n}: {code} twice in entry {cur}')
        entries[cur][code] = text.replace('\\n', '\n')
    return entries


def main():
    keys = json.load(open(sys.argv[1], encoding='utf-8'))
    tables = {}
    for code, name in LANGS.items():
        path = os.path.join(ROOT, 'data/lang', code + '.json')
        old = json.load(open(path, encoding='utf-8')).get('strings', {}) if os.path.exists(path) else {}
        tables[code] = dict(old)
    count = 0
    for batch in sys.argv[2:]:
        for i, langs in parse(batch).items():
            if i >= len(keys):
                sys.exit(f'{batch}: entry {i}: there are only {len(keys)} keys')
            key = keys[i]
            missing = set(LANGS) - set(langs)
            if missing:
                sys.exit(f'{batch}: entry {i} lacks {sorted(missing)}')
            for code, text in langs.items():
                if is_count(key):
                    one, other = key.split('|', 1)
                    parts = [p for p in text.split('‖')]
                    if text.strip() == '=':
                        parts = [one, other]
                    if len(parts) == 1:
                        parts = parts * 2
                    forms = dict(zip(['one', 'other'], [p.strip() for p in parts[:2]]))
                    if code == 'fr':
                        forms = {k: french(v) for k, v in forms.items()}
                    tables[code][key] = {f: forms[f] for f in FORMS[code]}
                else:
                    value = english(key) if text.strip() == '=' else edges(key, text)
                    tables[code][key] = french(value) if code == 'fr' else value
            count += 1
    os.makedirs(os.path.join(ROOT, 'data/lang'), exist_ok=True)
    for code, strings in tables.items():
        out = {'meta': {'language': code, 'name': LANGS[code], 'note': NOTE}, 'strings': dict(sorted(strings.items()))}
        with open(os.path.join(ROOT, 'data/lang', code + '.json'), 'w', encoding='utf-8') as f:
            json.dump(out, f, ensure_ascii=False, indent=1)
            f.write('\n')
    print(f'{count} entries merged into {", ".join(LANGS)}')


if __name__ == '__main__':
    main()
