#!/usr/bin/env python3
"""Check literal localization keys without running the app or reading user data."""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]


def unescape(value):
    value = re.sub(r'\\u\{([0-9a-fA-F]+)\}', lambda match: chr(int(match[1], 16)), value)
    return re.sub(r'\\([nrt"\\])', lambda match: {'n': '\n', 'r': '\r', 't': '\t', '"': '"', '\\': '\\'}[match[1]], value)


def strings(text):
    nodes = []

    def string(index):
        start = index
        triple = text.startswith('"""', index)
        quote = '"""' if triple else '"'
        index += len(quote)
        parts, plain = [], ''
        while index < len(text):
            if text.startswith(quote, index):
                end = index + len(quote)
                parts.append(plain)
                key = unescape(''.join(parts))
                if triple:
                    closing = text[text.rfind('\n', start, end) + 1:index]
                    if closing.isspace() or not closing:
                        key = key.removeprefix('\n')
                        key = '\n'.join(line[len(closing):] if line.startswith(closing) else line for line in key.split('\n'))
                        key = key.removesuffix('\n')
                nodes.append((start, key))
                return end
            if text.startswith('\\(', index):
                parts.extend([plain, '%@'])
                plain = ''
                index = expression(index + 2)
                continue
            if text[index] == '\\' and index + 1 < len(text):
                plain += text[index:index + 2]
                index += 2
                continue
            plain += text[index]
            index += 1
        raise ValueError('Unterminated Swift string')

    def expression(index):
        depth = 1
        while index < len(text):
            if text[index] == '"':
                index = string(index)
                continue
            if text[index] == '(':
                depth += 1
            if text[index] == ')':
                depth -= 1
                if depth == 0:
                    return index + 1
            index += 1
        raise ValueError('Unterminated Swift interpolation')

    index = 0
    while index < len(text):
        if text.startswith('//', index):
            end = text.find('\n', index)
            index = len(text) if end < 0 else end + 1
        elif text.startswith('/*', index):
            depth = 1
            index += 2
            while depth and index < len(text):
                if text.startswith('/*', index):
                    depth += 1
                    index += 2
                elif text.startswith('*/', index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            if depth:
                raise ValueError('Unterminated Swift comment')
        elif text[index] == '"':
            index = string(index)
        else:
            index += 1
    return nodes


def main():
    catalog = json.loads((ROOT / 'App/Resources/Localization/en.json').read_text())
    errors, keys = [], set()
    for key, value in catalog.items():
        if not isinstance(value, str) or not value:
            errors.append('Empty/non-string translation: ' + key)
        elif key.count('%@') != value.count('%@'):
            errors.append('Interpolation mismatch: ' + key)
        elif re.search('[А-Яа-яЁё]', value):
            errors.append('Untranslated Cyrillic: ' + key)
    for folder in ('App', 'Domain', 'Storage', 'AI/Local', 'AI/Host'):
        for path in sorted((ROOT / folder).rglob('*.swift')):
            text = path.read_text()
            for start, key in strings(text):
                # Dynamic stored names/content and parsing literals are not UI keys.
                if not re.search(r'\bVL\.(?:text|string)\(\s*$', text[:start]):
                    continue
                keys.add(key)
                if key not in catalog and re.search('[А-Яа-яЁё]', key):
                    line = text[:start].count('\n') + 1
                    errors.append(f'{path.relative_to(ROOT)}:{line}: missing localization key {key!r}')
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'PASS {len(catalog)} catalog entries and {len(keys)} literal source keys: interpolation, English values and literal coverage. Dynamic content/prompt behavior requires separate checks.')


if __name__ == '__main__':
    main()
