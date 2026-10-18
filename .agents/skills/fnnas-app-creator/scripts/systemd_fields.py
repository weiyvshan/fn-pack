"""Encode systemd path scalars and word-list items separately."""
import os


def path_text(value):
    text = os.fspath(value)
    if not isinstance(text, str) or not text.startswith('/'):
        raise ValueError('Unit paths must be absolute text paths')
    if any(ord(char) < 32 or ord(char) == 127 for char in text):
        raise ValueError('Unit paths must not contain control characters')
    if text[-1].isspace():
        raise ValueError('Trailing whitespace is ambiguous in unit path scalars')
    return text


def unit_path(value):
    # WorkingDirectory/EnvironmentFile consume a whole scalar, not shell words.
    return path_text(value).replace('%', '%%')


def unit_word(value):
    # ExecStart requires the ':' prefix to keep dollar expansions literal.
    text = path_text(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
    return '"' + text + '"'
