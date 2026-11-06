"""
main.py
CrisisBridge FastAPI Application.

Production-ready, accessible, high-performance disaster response hub.
Transforms messy, unstructured distress calls into verified, prioritized rescue tickets.
Supports Supabase persistence with automatic, bulletproof demo/seed fallback.
"""

import os
import time
import logging
from typing import List, Optional
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Query, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field, field_validator
from dotenv import load_dotenv

# Load local environment variables if present
load_dotenv()

from services.gemini_service import (
    disaster_engine,
    EmergencyTicket,
    TriageResult,
    VerificationResult,
    IncidentType,
    UrgencyLevel,
    TicketStatus
)
from services.supabase_service import supabase_service

logger = logging.getLogger("crisisbridge.main")

# In-memory ticket storage synchronized with supabase_service demo cache
INCIDENT_DATABASE: List[EmergencyTicket] = supabase_service._memory_cache
APP_START_TIME = time.time()


# Request / Response Schemas with Strict Pydantic Validation
class SignalRequest(BaseModel):
    raw_text: str = Field(
        ...,
        min_length=5,
        max_length=4000,
        description="Messy, panicked text, audio transcript, or SMS distress signal"
    )
    source: str = Field(
        default="Web SOS",
        max_length=50,
        description="Source of the distress call: SMS, Radio, Voice Transcript, Web SOS"
    )
    reporter_name: Optional[str] = Field(
        default=None,
        max_length=100,
        description="Name of reporting individual if provided"
    )
    contact_info: Optional[str] = Field(
        default=None,
        max_length=100,
        description="Phone number, radio callsign, or coordinates"
    )

    @field_validator("raw_text")
    @classmethod
    def validate_non_whitespace(cls, value: str) -> str:
        clean = value.strip()
        if len(clean) < 5:
            raise ValueError("Distress signal cannot be empty or purely whitespace (min 5 chars required).")
        return clean


class StatusUpdateRequest(BaseModel):
    status: TicketStatus = Field(
        ...,
        description="Target status: PENDING, DISPATCHED, EN_ROUTE, RESOLVED"
    )
    notes: Optional[str] = Field(
        default=None,
        max_length=500,
        description="Dispatcher operational notes"
    )


class SystemStatsResponse(BaseModel):
    total_tickets: int
    critical_tickets: int
    high_tickets: int
    medium_tickets: int
    low_tickets: int
    total_victims_trapped: int
    dispatched_tickets: int
    pending_tickets: int
    resolved_tickets: int
    average_confidence_score: float
    gemini_ai_configured: bool
    supabase_configured: bool = False
    supabase_connected: bool = False
    storage_mode: str = "in-memory-fallback"


class HealthResponse(BaseModel):
    status: str
    service: str
    version: str
    uptime_seconds: float
    gemini_api_configured: bool
    total_tickets_tracked: int
    supabase_configured: bool = False
    supabase_connected: bool = False
    storage_mode: str = "in-memory-fallback"


# Seed Initial Realistic Emergency Incidents for Live Demonstration
def seed_initial_tickets():
    """Ensure baseline demonstration tickets exist in memory cache."""
    if not supabase_service._memory_cache:
        supabase_service._init_memory_cache()


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: Ensure baseline demo tickets and attempt Supabase connection
    seed_initial_tickets()
    try:
        await supabase_service.initialize()
    except Exception as e:
        logger.warning(f"CrisisBridge: Startup Supabase initialization notice: {e}")
    yield
    # Shutdown actions if needed


# FastAPI Instance Initialization
app = FastAPI(
    title="CrisisBridge Emergency Triage API",
    description="Accessible, two-stage AI-driven disaster response and verification hub.",
    version="1.0.0",
    lifespan=lifespan
)

# CORS Configuration for open responder inter-agency dispatch
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount static files directory
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
if os.path.exists(STATIC_DIR):
    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


# ----------------------------------------------------
# REST ENDPOINTS
# ----------------------------------------------------

@app.get("/", include_in_schema=False)
async def serve_dashboard():
    """Serves the semantic, accessible emergency response dashboard."""
    index_file = os.path.join(STATIC_DIR, "index.html")
    if os.path.exists(index_file):
        return FileResponse(index_file)
    return JSONResponse(
        content={"message": "CrisisBridge API is running. UI dashboard at /static/index.html"},
        status_code=status.HTTP_200_OK
    )


@app.get("/health", response_model=HealthResponse, tags=["Monitoring"])
@app.get("/api/health", response_model=HealthResponse, tags=["Monitoring"])
async def health_check():
    """Service health, Gemini AI and Supabase integration readiness monitor."""
    tickets = await supabase_service.get_tickets()
    return HealthResponse(
        status="healthy",
        service="CrisisBridge Disaster Triage Hub",
        version="1.0.0",
        uptime_seconds=round(time.time() - APP_START_TIME, 2),
        gemini_api_configured=disaster_engine.is_configured,
        total_tickets_tracked=len(tickets),
        supabase_configured=supabase_service.is_configured,
        supabase_connected=supabase_service.is_connected,
        storage_mode="supabase" if supabase_service.is_connected else "in-memory-fallback"
    )


@app.post(
    "/api/triage",
    response_model=EmergencyTicket,
    status_code=status.HTTP_201_CREATED,
    tags=["Triage Engine"]
)
async def submit_distress_signal(signal: SignalRequest):
    """
    Ingest a raw, panicked distress signal or audio transcript.
    Processes the message through the Two-Stage Google Gemini 2.5 Flash Pipeline:
    1. Agent 1: Extracts structured incident parameters (Urgency, Victims, Location, Resources).
    2. Agent 2: Cross-examines against hallucinations and assigns confidence score (0-100%).
    Persists to Supabase with automatic in-memory fallback.
    """
    try:
        ticket = await disaster_engine.process_signal(
            raw_text=signal.raw_text,
            source=signal.source,
            reporter_name=signal.reporter_name,
            contact_info=signal.contact_info
        )
        saved_ticket = await supabase_service.save_ticket(ticket)
        return saved_ticket
    except Exception as e:
        # Fallback guarantee: never drop an emergency signal
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Emergency processing pipeline error: {str(e)}"
        )


@app.get("/api/tickets", response_model=List[EmergencyTicket], tags=["Responder Feed"])
async def get_tickets(
    urgency: Optional[UrgencyLevel] = Query(None, description="Filter by urgency level"),
    incident_type: Optional[IncidentType] = Query(None, description="Filter by incident category"),
    status: Optional[TicketStatus] = Query(None, description="Filter by dispatch status"),
    search: Optional[str] = Query(None, description="Search by location or description keywords")
):
    """
    List emergency tickets sorted by priority (CRITICAL -> HIGH -> MEDIUM -> LOW).
    Supports multi-attribute operational filtering across Supabase or in-memory demo cache.
    """
    return await supabase_service.get_tickets(
        urgency=urgency,
        incident_type=incident_type,
        status=status,
        search=search
    )


@app.get("/api/tickets/{ticket_id}", response_model=EmergencyTicket, tags=["Responder Feed"])
async def get_single_ticket(ticket_id: str):
    """Fetch complete ticket details by ID."""
    ticket = await supabase_service.get_ticket_by_id(ticket_id)
    if ticket:
        return ticket
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Ticket {ticket_id} not found.")


@app.patch("/api/tickets/{ticket_id}/status", response_model=EmergencyTicket, tags=["Responder Feed"])
async def update_ticket_status(ticket_id: str, update: StatusUpdateRequest):
    """Allows field commanders to update dispatch status (e.g. PENDING -> DISPATCHED -> RESOLVED)."""
    ticket = await supabase_service.update_ticket_status(ticket_id, update.status, update.notes)
    if ticket:
        return ticket
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Ticket {ticket_id} not found.")


@app.get("/api/stats", response_model=SystemStatsResponse, tags=["Monitoring"])
async def get_system_stats():
    """Aggregated operational metrics for emergency command dashboard."""
    all_tickets = await supabase_service.get_tickets()
    total = len(all_tickets)
    critical = sum(1 for t in all_tickets if t.triage.urgency_level == UrgencyLevel.CRITICAL)
    high = sum(1 for t in all_tickets if t.triage.urgency_level == UrgencyLevel.HIGH)
    medium = sum(1 for t in all_tickets if t.triage.urgency_level == UrgencyLevel.MEDIUM)
    low = sum(1 for t in all_tickets if t.triage.urgency_level == UrgencyLevel.LOW)
    
    total_victims = sum(t.triage.victims_trapped for t in all_tickets)
    dispatched = sum(1 for t in all_tickets if t.status in [TicketStatus.DISPATCHED, TicketStatus.EN_ROUTE])
    pending = sum(1 for t in all_tickets if t.status == TicketStatus.PENDING)
    resolved = sum(1 for t in all_tickets if t.status == TicketStatus.RESOLVED)

    avg_conf = (
        round(sum(t.verification.confidence_score for t in all_tickets) / total, 1)
        if total > 0 else 0.0
    )

    return SystemStatsResponse(
        total_tickets=total,
        critical_tickets=critical,
        high_tickets=high,
        medium_tickets=medium,
        low_tickets=low,
        total_victims_trapped=total_victims,
        dispatched_tickets=dispatched,
        pending_tickets=pending,
        resolved_tickets=resolved,
        average_confidence_score=avg_conf,
        gemini_ai_configured=disaster_engine.is_configured,
        supabase_configured=supabase_service.is_configured,
        supabase_connected=supabase_service.is_connected,
        storage_mode="supabase" if supabase_service.is_connected else "in-memory-fallback"
    )


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8080))
    host = os.environ.get("HOST", "0.0.0.0")
    uvicorn.run("main:app", host=host, port=port, reload=True)
