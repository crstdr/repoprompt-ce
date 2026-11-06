#!/usr/bin/env python3
"""Focused behavior tests for the oversight guidance measurement helper."""

import re
import sys
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import measure_agent_session_link_guidance as guidance  # noqa: E402


class AgentSessionLinkGuidanceMeasurementTests(unittest.TestCase):
    def test_inventory_refuses_to_measure_without_guidance_revision(self):
        source = guidance.contents("worktree", guidance.PROMPTS)
        without_revision = re.sub(
            r"(?m)^[ \t]*static let currentInventoryGuidanceRevision: UInt64 = \d+[ \t]*\n",
            "",
            source,
        )
        self.assertNotEqual(source, without_revision)
        with mock.patch.object(guidance, "contents", return_value=without_revision):
            with self.assertRaisesRegex(ValueError, "currentInventoryGuidanceRevision"):
                guidance.inventory("worktree", managed=False)


if __name__ == "__main__":
    unittest.main()
