"""
api/index.py
Vercel Serverless Function entrypoint for CrisisBridge.
Exports FastAPI app from main.
"""

import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from main import app
