"""
api/index.py
Vercel Serverless Function entrypoint for CrisisBridge FastAPI application.
Routes all requests to main:app.
"""

import sys
import os

# Add root directory to path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from main import app
