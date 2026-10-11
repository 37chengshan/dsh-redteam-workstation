#!/usr/bin/env python3
"""
validate-package.py
===================
Lint an installer package for the encoding and escaping bugs that silently
break Windows batch installers.

WHY THIS EXISTS
---------------
Three classes of bug destroy .cmd / .ps1 installers on Windows:

  1. Non-ASCII bytes inside a .cmd / .bat file
     cmd.exe parses batch files byte-by-byte using the OEM code page and
     IGNORES chcp. A UTF-8 multi-byte sequence (Chinese text, box-drawing
     characters such as U+2500) desynchronises the parser and can swallow
     line breaks. The script then dies before it can even reach a `pause`,
     which looks like "the window flashes and closes".

  2. Missing UTF-8 BOM in a .ps1 file
     PowerShell 5.1 decodes a BOM-less script using the ANSI code page, so
     every non-ASCII character is mangled.

  3. PowerShell automatic-variable collisions
     $host is a READ-ONLY automatic variable. Assigning to it fails silently
     and the previous value survives. In this project that produced a
     Cloudflare DNS record literally named
     "system.management.automation.internal.host.internalhost.<domain>".

  4. $var: without braces
     "$server:9100" is parsed as a scope qualifier, not string interpolation.
     Write "${server}:9100".

  5. CRLF in shell scripts
     bash chokes with "$'\r': command not found".

Usage
-----
    python3 validate-package.py [package_root]

Exit codes
----------
    0  no errors (warnings may still be present)
    1  at least one error
"""

import os
import re
import sys

# PowerShell automatic variables that must never be used as our own names.
RESERVED = {
    'host', 'input', 'args', 'error', 'matches', 'profile', 'psitem',
    'true', 'false', 'home', 'pid', 'pwd', 'pshome', 'shellid',
    'stacktrace', 'this', 'foreach', 'switch', 'myinvocation',
    'executioncontext', 'psversiontable', 'psscriptroot', 'pscommandpath',
    'psstyle', 'iswindows', 'islinux', 'ismacos', 'lastexitcode',
}

# $name:  where name is not a known drive/scope -> needs ${name}
BAD_DOLLAR_COLON = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*):(?![A-Za-z0-9_])')

# Shell-script basenames with no extension
SHELL_BASENAMES = {'rt', 'rt-bootstrap'}


def has_odd_quotes(line: str) -> bool:
    """True when a PowerShell line looks like it has an unterminated '...' string."""
    if line.lstrip().startswith('#'):
        return False
    if '@"' in line or "@'" in line or '"@' in line or "'@" in line:
        return False
    return line.count("'") % 2 == 1


def check_batch(raw: bytes, rel: str, out: list) -> None:
    try:
        raw.decode('ascii')
    except UnicodeDecodeError as exc:
        snippet = raw[exc.start:exc.start + 8]
        out.append((rel, 'ERROR',
                    'non-ASCII byte at offset {0}: {1!r}\n'
                    '          cmd.exe will mis-parse this; the script crashes before pause'
                    .format(exc.start, snippet)))
    if b'\n' in raw.replace(b'\r\n', b''):
        out.append((rel, 'WARN', 'bare LF line ending (use CRLF)'))


def check_ps1(raw: bytes, rel: str, out: list) -> None:
    bom = raw[:3] == b'\xef\xbb\xbf'
    body = raw[3:] if bom else raw

    if not bom:
        out.append((rel, 'ERROR',
                    'missing UTF-8 BOM\n'
                    '          PowerShell 5.1 reads it as ANSI and mangles non-ASCII text'))

    try:
        text = body.decode('utf-8')
    except UnicodeDecodeError as exc:
        out.append((rel, 'ERROR', 'not valid UTF-8: {0}'.format(exc)))
        return

    if b'\n' in raw.replace(b'\r\n', b''):
        out.append((rel, 'WARN', 'bare LF line ending (use CRLF)'))

    in_block = False
    for lineno, line in enumerate(text.split('\n'), 1):
        stripped = line.strip()

        # ---- block comment tracking: <# ... #> ----
        if in_block:
            if '#>' in line:
                in_block = False
            continue
        if '<#' in line:
            if '#>' not in line:
                in_block = True
            continue

        # ---- line comment ----
        if stripped.startswith('#'):
            continue

        # ---- reserved automatic variable assignment ----
        match = re.match(r'\s*\$([A-Za-z_][A-Za-z0-9_]*)\s*=', line)
        if match:
            name = match.group(1).lower()
            # '$null = ...' is the idiomatic way to discard output
            if name in RESERVED:
                out.append((rel, 'ERROR',
                            'L{0}: assignment to reserved automatic variable ${1}\n'
                            '          the assignment silently fails and the old value is used'
                            .format(lineno, match.group(1))))

        # ---- $var: needing braces ----
        dc = BAD_DOLLAR_COLON.search(line)
        if dc and dc.group(1).lower() != 'env':
            out.append((rel, 'ERROR',
                        'L{0}: ${1}: needs ${{{1}}} delimiters\n'
                        "          '$var:' is parsed as a scope or drive qualifier"
                        .format(lineno, dc.group(1))))

        # ---- likely unterminated single-quoted string ----
        if has_odd_quotes(line):
            out.append((rel, 'WARN',
                        'L{0}: odd number of single quotes\n'
                        "          check for an unescaped apostrophe inside a '...' string"
                        .format(lineno)))


def check_shell(raw: bytes, rel: str, out: list) -> None:
    if b'\r\n' in raw:
        out.append((rel, 'ERROR',
                    'CRLF line endings in a shell script\n'
                    '          bash fails with "$\r: command not found"'))


def should_scan(rel: str) -> str:
    low = rel.lower()
    if low.endswith(('.cmd', '.bat')):
        return 'batch'
    if low.endswith('.ps1'):
        return 'ps1'
    if low.endswith('.sh') or os.path.basename(rel) in SHELL_BASENAMES:
        return 'shell'
    return ''


def main() -> int:
    if len(sys.argv) > 1:
        root = sys.argv[1]
    else:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    findings = []
    scanned = 0

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in ('.git', 'node_modules', '__pycache__')]
        for filename in sorted(filenames):
            full = os.path.join(dirpath, filename)
            rel = os.path.relpath(full, root)
            kind = should_scan(rel)
            if not kind:
                continue
            scanned += 1
            raw = open(full, 'rb').read()
            if kind == 'batch':
                check_batch(raw, rel, findings)
            elif kind == 'ps1':
                check_ps1(raw, rel, findings)
            else:
                check_shell(raw, rel, findings)

    print('scanned {0} script file(s) under {1}'.format(scanned, root))
    print()

    if not findings:
        print('  ALL CHECKS PASSED')
        print()
        print('    .cmd / .bat : pure ASCII + CRLF')
        print('    .ps1        : UTF-8 + BOM + CRLF, no reserved-variable collisions')
        print('    .sh         : LF')
        return 0

    errors = [f for f in findings if f[1] == 'ERROR']
    warns = [f for f in findings if f[1] == 'WARN']

    for rel, level, msg in findings:
        tag = 'ERROR' if level == 'ERROR' else ' warn'
        print('  [{0}] {1}'.format(tag, rel))
        print('          {0}'.format(msg))

    print()
    print('  {0} error(s), {1} warning(s)'.format(len(errors), len(warns)))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
