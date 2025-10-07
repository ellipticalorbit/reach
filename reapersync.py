# -*- coding: utf-8 -*-
# reapersync.py - Python entrypoint

from __future__ import annotations

try:
	from reaper_python import *  # noqa: F401,F403
except Exception:
	def __getattr__(name):
		raise RuntimeError("Run this inside REAPER's Python")

import reapersynclib as lib


def main() -> None:
	lib.self_update()
	lib.refresh()
	RPR_ShowConsoleMsg("Project Refreshed\n")


if __name__ == "__main__":
	main() 