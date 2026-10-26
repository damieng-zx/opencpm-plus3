"""Static regression tests for OpenCP/M +3.

These tests run without an emulator.  They parse the ZPA sources and, when a
build is present, the sjasmplus listing.  Run after `build.cmd`:

    python3 -m unittest discover -s tests
"""

from .layout import ROOT, labels, source  # noqa: F401
