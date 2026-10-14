#!/usr/bin/env python3
"""Assemble a vps2img-* script from fragments under src/.

See docs/preprocessor.md for the directive reference.  The fragments are read
from a list of directories in ascending basename-number order, and a small
line-oriented directive language lets one fragment pull a shared body into
another file, including the body of a heredoc, substituting @KEY@ placeholders
that were set with (#@DEFINE@).

Only the Python standard library is used.
"""

import argparse
import glob
import os
import re
import sys

DIRECTIVE = re.compile(r'^([ \t]*)\(#@([A-Z]+)@([A-Za-z]*)\)[ \t]?(.*)$')
PLACEHOLDER = re.compile(r'@([A-Za-z_][A-Za-z0-9_]*)@')
HEREDOC_WORD = re.compile(r"<<-?\s*\\?(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
LEADING_NUMBER = re.compile(r'^(\d+)')


class BuildError(Exception):
    pass


class Builder:
    def __init__(self, root):
        self.root = root
        self.out = []
        self.globals = {}
        self.locals = []
        self.delims = []

    # --- fragment discovery -------------------------------------------------
    def fragments(self, dirs):
        found = []
        for directory in dirs:
            paths = sorted(glob.glob(os.path.join(directory, '*.sh')))
            if not paths:
                raise BuildError('no fragments in %s' % directory)
            for path in paths:
                name = os.path.basename(path)
                match = LEADING_NUMBER.match(name)
                if not match:
                    raise BuildError('fragment without a leading number: %s' % path)
                found.append((int(match.group(1)), path))
        numbers = [n for n, _ in found]
        duplicates = sorted({n for n in numbers if numbers.count(n) > 1})
        if duplicates:
            raise BuildError('duplicate fragment numbers: %s' % duplicates)
        return [path for _, path in sorted(found)]

    # --- variable scopes ----------------------------------------------------
    def lookup(self, key):
        for scope in reversed(self.locals):
            if key in scope:
                return scope[key]
        if key in self.globals:
            return self.globals[key]
        raise BuildError('undefined variable @%s@' % key)

    def substitute(self, line):
        return PLACEHOLDER.sub(lambda m: self.lookup(m.group(1)), line)

    # --- heredoc tracking (best effort) ------------------------------------
    def track(self, line):
        stripped = line.lstrip('\t')
        if self.delims and stripped == self.delims[-1]:
            self.delims.pop()
            return
        for _, word in HEREDOC_WORD.findall(line):
            self.delims.append(word)

    def emit(self, line):
        self.out.append(line)
        self.track(line)

    # --- directive handlers -------------------------------------------------
    def read(self, relative):
        if re.search(r'[|\s]', relative):
            raise BuildError('bad path (space or pipe): %r' % relative)
        path = os.path.join(self.root, relative)
        if not os.path.isfile(path):
            raise BuildError('missing file: %s' % relative)
        with open(path) as handle:
            return handle.read()

    def define(self, rest, local):
        if '=' not in rest:
            raise BuildError('DEFINE needs KEY=VALUE: %r' % rest)
        key, value = rest.split('=', 1)
        key = key.strip()
        if not PLACEHOLDER.fullmatch('@%s@' % key):
            raise BuildError('bad DEFINE name: %r' % key)
        if local:
            self.locals[-1][key] = value
        else:
            self.globals[key] = value

    def include(self, rest, expand):
        self.locals.append({})
        try:
            self.render(self.read(rest.strip()), expand)
        finally:
            self.locals.pop()

    def heredoc(self, rest, expand):
        if '|' not in rest:
            raise BuildError('HEREDOC needs <command> | <path>: %r' % rest)
        command, path = rest.rsplit('|', 1)
        command = command.strip()
        path = path.strip()
        match = HEREDOC_WORD.search(command)
        if not match:
            raise BuildError('HEREDOC command has no <<word: %r' % command)
        terminator = match.group(2)

        self.emit(command)
        active = list(self.delims)
        saved_out, saved_delims = self.out, self.delims
        self.out, self.delims = [], list(active)
        self.render(self.read(path), expand)
        produced, self.out, self.delims = self.out, saved_out, saved_delims
        for line in produced:
            if line in active:
                raise BuildError('heredoc body contains active delimiter %r' % line)
        for line in produced:
            self.emit(line)
        self.emit(terminator)

    # --- core ---------------------------------------------------------------
    def render(self, text, expand):
        if text.endswith('\n'):
            text = text[:-1]
        for line in text.split('\n'):
            match = DIRECTIVE.match(line)
            if match and not expand:
                self.emit(line)
                continue
            if not match:
                self.emit(self.substitute(line))
                continue
            keyword = match.group(2)
            modifier = match.group(3)
            rest = match.group(4)
            if keyword == 'DEFINE':
                if modifier not in ('', 'global', 'local'):
                    raise BuildError('bad DEFINE modifier %r' % modifier)
                self.define(rest, modifier == 'local')
            elif keyword == 'INCLUDE':
                if modifier not in ('', 'literal', 'expand'):
                    raise BuildError('bad INCLUDE modifier %r' % modifier)
                self.include(rest, modifier == 'expand')
            elif keyword == 'HEREDOC':
                if modifier not in ('', 'literal', 'expand'):
                    raise BuildError('bad HEREDOC modifier %r' % modifier)
                self.heredoc(rest, modifier == 'expand')
            else:
                raise BuildError('unknown directive %r' % keyword)

    def build(self, dirs):
        for path in self.fragments(dirs):
            with open(path) as handle:
                text = handle.read()
            self.locals.append({})
            try:
                self.render(text, True)
            finally:
                self.locals.pop()
        output = '\n'.join(self.out)
        if '(#@' in output:
            raise BuildError('a directive was left in the output')
        return output + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--program', required=True)
    parser.add_argument('--dirs', nargs='+', required=True)
    parser.add_argument('--assets', nargs='+', default=[])
    parser.add_argument('--root', default='.')
    if len(sys.argv) == 1:
        parser.print_help()
        return 0
    args = parser.parse_args()

    builder = Builder(args.root)
    try:
        sys.stdout.write(builder.build(args.dirs))
    except BuildError as error:
        sys.stderr.write('%s: %s\n' % (args.program, error))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
