"""Test-wide defaults."""
import os

# The luau-lsp API check costs about two seconds per written file; the scripted builds in the workflow tests write
# hundreds. tests/test_typecheck.py turns it back on for its own tests.
os.environ.setdefault("HARNESS_TYPECHECK", "0")
