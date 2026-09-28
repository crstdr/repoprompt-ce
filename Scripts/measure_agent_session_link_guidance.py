#!/usr/bin/env python3
"""Replay the fixed one-link oversight inventory fixture at two Git refs.

Usage: python3 Scripts/measure_agent_session_link_guidance.py 3e5d805e worktree
Both refs must contain the one-line `respondHint` literal; older refs need their
inventory/tool counts measured separately rather than silently omitting the hint.
This is a static literal estimate, not an automated Swift-renderer check. The fixture
uses the bare, host-determined tool name and includes its naming guidance. Compare
the resulting counts against a Swift-rendered one-link fixture when changing the renderer.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROMPTS = "Sources/RepoPrompt/Infrastructure/AI/Prompts/AgentSessionLinkPrompts.swift"
SPEC = "docs/spec/mcp-domain-canonical-tool-definitions.generated.json"
TOOL = "agent_session_link"
TARGET = "8B91C0E0-0000-0000-0000-00000000E572"
NAME = "Build API"


def contents(ref, path):
    if ref == "worktree":
        return (ROOT / path).read_text()
    return subprocess.check_output(
        ["git", "-C", str(ROOT), "show", f"{ref}:{path}"], text=True
    )


def section(source, start, end):
    return source[source.index(start) : source.index(end, source.index(start))]


def swift_literal(value):
    # Keep the capability-change interpolation for historical before-ref comparisons.
    for key, replacement in {
        "toolReference": TOOL,
        "server": "RepoPromptCE",
        "envelopeTag": "repoprompt_session_oversight",
        "capabilityChangeEnvelopeTag": "repoprompt_session_oversight_capability_change",
    }.items():
        value = value.replace(r"\(" + key + ")", replacement)
    if r"\(" in value:
        raise ValueError(f"unhandled Swift interpolation: {value}")
    value = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda match: chr(int(match[1], 16)), value)
    return re.sub(
        r'\\([\\"nrt])',
        lambda match: {"\\": "\\", '"': '"', "n": "\n", "r": "\r", "t": "\t"}[match[1]],
        value,
    )


def literals(block):
    values = []
    for line in block.splitlines():
        line = line.strip()
        if line.startswith('"') and (line.endswith('"') or line.endswith('",')):
            values.append(swift_literal(line[1:-2] if line.endswith('",') else line[1:-1]))
    return values


def escaped(value):
    return "".join(
        {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;"}.get(char, char)
        for char in value
    )


def inventory(ref, managed):
    source = contents(ref, PROMPTS)
    guidance = section(source, "private static func guidance(toolReference: String)", "        let escapedLines =")
    initial = literals(section(guidance, "var lines = [", "lines.append(contentsOf: hostNamingGuidance"))
    trailing = literals(guidance)[len(initial) :]
    host = literals(section(source, "private static func hostNamingGuidance(toolReference: String)", "    // MARK: Escaping"))
    autonomy = literals(section(source, "static let autonomyContract: [String] = [", "\n    ]"))
    lines = initial + host + autonomy + trailing
    guidance_revision = re.search(r"currentInventoryGuidanceRevision: UInt64 = (\d+)", source)
    revision_attribute = f' guidance_revision="{guidance_revision[1]}"' if guidance_revision else ""
    capabilities = "manage,poll,read,send_when_idle,wait" if managed else "poll,read,send_when_idle,wait"
    row = (
        f'<session id="{TARGET}" name="{escaped(NAME)}" capabilities="{capabilities}" '
        f'managed="{str(managed).lower()}" />'
    )
    return (
        f'<repoprompt_session_oversight revision="7"{revision_attribute} status="active">\n'
        "<guidance>\n" + "\n".join(map(escaped, lines)) + "\n</guidance>\n"
        f'<overseen_sessions count="1">\n{row}\n</overseen_sessions>\n'
        "</repoprompt_session_oversight>"
    )


def tool_definition(ref):
    snapshot = json.loads(contents(ref, SPEC))
    tool = next(item for item in snapshot["tools"] if item["name"] == TOOL)
    return json.dumps(tool, ensure_ascii=False, separators=(",", ":"))


def respond_hint(ref):
    source = contents(ref, PROMPTS)
    assignment = re.search(r"(?m)^[ \t]*static let respondHint[ \t]*=[ \t]*(?:\r?\n[ \t]*)?", source)
    if not assignment:
        raise ValueError(f"{ref}: respondHint assignment is missing from {PROMPTS}")
    match = re.match(r'"((?:[^"\\\r\n]|\\.)*)"[ \t]*(?:\r?\n|$)', source[assignment.end() :])
    if not match or re.match(r"[ \t]*\+", source[assignment.end() + match.end() :]):
        raise ValueError(f"{ref}: respondHint must be one complete Swift string literal on one line")
    hint = swift_literal(match[1])
    if "\n" in hint or "\r" in hint:
        raise ValueError(f"{ref}: respondHint must not contain a newline")
    return hint


def report(ref):
    tool_chars = len(tool_definition(ref))
    print(f"{ref} tool: {tool_chars} chars, ~{tool_chars / 4:.2f} tokens")
    for managed in (False, True):
        chars = len(inventory(ref, managed))
        print(f"{ref} {'managed' if managed else 'watch'} inventory: {chars} chars, ~{chars / 4:.2f} tokens")
    hint = respond_hint(ref)
    print(f"{ref} respond_hint: {len(hint)} chars, ~{len(hint) / 4:.2f} tokens")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: measure_agent_session_link_guidance.py BEFORE_REF AFTER_REF|worktree")
    for revision in sys.argv[1:]:
        report(revision)
