"""Fixed static name extraction for the four selected Guardian source files.

This is deliberately restricted to their literal names and three existing loop
forms. It refuses unsupported source syntax rather than guessing test discovery.
No Dart, SDK, browser or candidate imports occur here.
"""
import re

SELECTORS = ['test/workspace_flow_entry_browser_test.dart',
             'test/audit_export_route_test.dart',
             'test/approval_help_flow_browser_test.dart',
             'test/notification_help_scope_browser_test.dart']
COUNTS = [8, 4, 19, 7]


def tokens(text):
    result = []
    def quoted(start):
        quote = text[start]
        cursor = start + 1
        while cursor < len(text):
            if text[cursor] == '\\':
                cursor += 2
            elif text.startswith('${', cursor):
                cursor += 2
                depth = 1
                while depth:
                    assert cursor < len(text), 'Unclosed interpolation'
                    if text[cursor] in "'\"":
                        cursor = quoted(cursor)
                    else:
                        depth += (text[cursor] == '{') - (text[cursor] == '}')
                        cursor += 1
            elif text[cursor] == quote:
                return cursor + 1
            else:
                cursor += 1
        raise AssertionError('Unclosed source string')
    cursor = 0
    while cursor < len(text):
        if text[cursor].isspace():
            cursor += 1
            continue
        if text.startswith('//', cursor):
            end = text.find('\n', cursor)
            cursor = len(text) if end < 0 else end + 1
            continue
        if text.startswith('/*', cursor):
            end = text.find('*/', cursor + 2)
            assert end >= 0, 'Unclosed source comment'
            cursor = end + 2
            continue
        start = cursor
        if text[cursor] in "'\"":
            cursor = quoted(cursor)
            result.append(('string', text[start + 1:cursor - 1], start, cursor))
        else:
            word = re.match(r'[A-Za-z_$][A-Za-z0-9_$]*', text[cursor:])
            cursor += len(word[0]) if word else 1
            result.append(('token', text[start:cursor], start, cursor))
    return result


def derive(text, selector):
    assert selector in SELECTORS and "@TestOn('browser')" in text
    stream = tokens(text)
    values = [row[1] for row in stream]
    assert not any(value in ('group', 'test', 'skip') and kind == 'token'
                   for kind, value, start, end in stream), 'Unsupported test/group/skip declaration'
    loops = []
    for index, value in enumerate(values):
        if value != 'for' or values[index + 1:index + 3] != ['(', 'final']:
            continue
        variable = values[index + 3]
        if variable not in ('loss', 'action', 'succeeds'):
            continue
        assert values[index + 4:index + 6] == ['in', '[']
        close = values.index(']', index + 6)
        assert values[close + 1:close + 3] == [')', '{']
        members = []
        for item in stream[index + 6:close]:
            if item[1] == ',':
                continue
            assert item[0] == 'string' or item[1] in ('true', 'false')
            members.append(item[1])
        expected = {'loss': (['real selection then failure', 'dispose']
                             if selector == 'test/notification_help_scope_browser_test.dart'
                             else ['actor ABA', 'generation', 'dispose']),
                    'action': ['批准', '拒绝', '撤销批准'],
                    'succeeds': ['true', 'false']}[variable]
        assert members == expected, 'Selected loop values changed'
        depth = 1
        end = close + 3
        while depth:
            assert end < len(stream)
            if stream[end][0] == 'token':
                depth += (values[end] == '{') - (values[end] == '}')
            end += 1
        loops.append((close + 2, end - 1, variable, members))
    declarations = []
    cases = []
    for index, value in enumerate(values):
        if value != 'testWidgets' or stream[index][0] != 'token':
            continue
        assert values[index + 1] == '('
        end = index + 2
        pieces = []
        while stream[end][0] == 'string':
            pieces.append(values[end])
            end += 1
        assert pieces and values[end] == ',', 'Nonliteral selected test name'
        template = ''.join(pieces)
        enclosing = [loop for loop in loops if loop[0] < index < loop[1]]
        assert len(enclosing) <= 1, 'Unexpected nested name expansion'
        line = text.count('\n', 0, stream[index][2]) + 1
        declaration = {'line': line, 'nameTemplate': template, 'expandedNames': []}
        variable, members = (enclosing[0][2], enclosing[0][3]) if enclosing else (None, [None])
        for member in members:
            name = template
            if variable in ('loss', 'action'):
                name = name.replace('$' + variable, member)
            elif variable == 'succeeds':
                expression = "${succeeds ? 'success' : 'error'}"
                assert expression in name, 'Unknown conditional interpolation'
                name = name.replace(expression, 'success' if member == 'true' else 'error')
            assert '$' not in name and '\\' not in name, 'Unsupported selected name interpolation/escape'
            declaration['expandedNames'].append(name)
            cases.append({'selector': selector, 'name': name, 'declarationLine': line,
                          'loopBinding': {variable: member} if variable else {}})
        declarations.append(declaration)
    assert len(cases) == COUNTS[SELECTORS.index(selector)], 'Selected source expansion count changed'
    assert len({row['name'] for row in cases}) == len(cases), 'Duplicate source-derived test name'
    return cases, declarations
