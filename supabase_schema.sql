-- ==============================================================================
-- CrisisBridge Master Supabase Schema
-- Application: CrisisBridge Emergency Disaster Triage Hub
-- Generated for Master Supabase SQL Editor
-- Features: Full schema, JSONB sync triggers, RPC stats function, RLS demo policies,
--           storage bucket setup, and realistic disaster seed data.
-- ==============================================================================

-- 1. EXTENSIONS
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 2. ENUM TYPES (Idempotent creation)
DO $$ BEGIN
    CREATE TYPE incident_type_enum AS ENUM ('Flood', 'Fire', 'Medical', 'Structural', 'Hazardous', 'Other');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE urgency_level_enum AS ENUM ('CRITICAL', 'HIGH', 'MEDIUM', 'LOW');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE ticket_status_enum AS ENUM ('PENDING', 'DISPATCHED', 'EN_ROUTE', 'RESOLVED');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- 3. PRIMARY TABLE: emergency_tickets
CREATE TABLE IF NOT EXISTS public.emergency_tickets (
    -- Unique Identifier
    ticket_id TEXT PRIMARY KEY,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    
    -- Ingest & Reporter Information
    raw_text TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'Web SOS',
    reporter_name TEXT,
    contact_info TEXT,
    status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'DISPATCHED', 'EN_ROUTE', 'RESOLVED')),
    
    -- Stage 1: Triage Extraction Parameters (Agent 1)
    incident_type TEXT NOT NULL DEFAULT 'Other' CHECK (incident_type IN ('Flood', 'Fire', 'Medical', 'Structural', 'Hazardous', 'Other')),
    urgency_level TEXT NOT NULL DEFAULT 'MEDIUM' CHECK (urgency_level IN ('CRITICAL', 'HIGH', 'MEDIUM', 'LOW')),
    victims_trapped INTEGER NOT NULL DEFAULT 0 CHECK (victims_trapped >= 0),
    location TEXT NOT NULL DEFAULT '',
    required_resources JSONB NOT NULL DEFAULT '[]'::jsonb,
    summary TEXT NOT NULL DEFAULT '',
    hazards_detected JSONB NOT NULL DEFAULT '[]'::jsonb,
    
    -- Stage 2: Safety & Anti-Hallucination Verification (Agent 2)
    confidence_score INTEGER NOT NULL DEFAULT 85 CHECK (confidence_score >= 0 AND confidence_score <= 100),
    verified BOOLEAN NOT NULL DEFAULT true,
    urgency_confirmation TEXT NOT NULL DEFAULT 'MEDIUM' CHECK (urgency_confirmation IN ('CRITICAL', 'HIGH', 'MEDIUM', 'LOW')),
    hallucination_detected BOOLEAN NOT NULL DEFAULT false,
    verification_reasoning TEXT NOT NULL DEFAULT '',
    flagged_inconsistencies JSONB NOT NULL DEFAULT '[]'::jsonb,
    recommended_action TEXT NOT NULL DEFAULT '',
    
    -- Pipeline Execution Metadata
    pipeline_latency_ms NUMERIC(10, 2) NOT NULL DEFAULT 0.0,
    engine_mode TEXT NOT NULL DEFAULT 'gemini-2.5-flash',
    dispatcher_notes TEXT,
    
    -- Nested Structured JSON Objects (Matches Pydantic EmergencyTicket Model directly)
    triage JSONB,
    verification JSONB
);

-- 4. VIEW ALIAS: tickets (Supports legacy code using supabase.from('tickets'))
CREATE OR REPLACE VIEW public.tickets AS 
SELECT * FROM public.emergency_tickets;

-- 5. PERFORMANCE INDEXES
CREATE INDEX IF NOT EXISTS idx_tickets_urgency ON public.emergency_tickets(urgency_level);
CREATE INDEX IF NOT EXISTS idx_tickets_status ON public.emergency_tickets(status);
CREATE INDEX IF NOT EXISTS idx_tickets_incident_type ON public.emergency_tickets(incident_type);
CREATE INDEX IF NOT EXISTS idx_tickets_created_at ON public.emergency_tickets(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tickets_confidence ON public.emergency_tickets(confidence_score);
CREATE INDEX IF NOT EXISTS idx_tickets_triage_gin ON public.emergency_tickets USING gin(triage);
CREATE INDEX IF NOT EXISTS idx_tickets_verification_gin ON public.emergency_tickets USING gin(verification);

-- 6. AUTOMATIC JSON & TIMESTAMP SYNCHRONIZATION TRIGGER
CREATE OR REPLACE FUNCTION public.sync_ticket_json_fields()
RETURNS TRIGGER AS $$
BEGIN
    -- Update timestamp
    NEW.updated_at := timezone('utc'::text, now());

    -- Synchronize triage JSONB if null or updated from columns
    IF NEW.triage IS NULL THEN
        NEW.triage := jsonb_build_object(
            'incident_type', NEW.incident_type,
            'urgency_level', NEW.urgency_level,
            'victims_trapped', NEW.victims_trapped,
            'location', NEW.location,
            'required_resources', NEW.required_resources,
            'summary', NEW.summary,
            'hazards_detected', NEW.hazards_detected
        );
    ELSE
        -- If triage JSON was supplied directly, keep top-level columns in sync
        IF NEW.triage ? 'incident_type' THEN
            NEW.incident_type := COALESCE(NEW.triage->>'incident_type', NEW.incident_type);
        END IF;
        IF NEW.triage ? 'urgency_level' THEN
            NEW.urgency_level := COALESCE(NEW.triage->>'urgency_level', NEW.urgency_level);
        END IF;
        IF NEW.triage ? 'victims_trapped' THEN
            NEW.victims_trapped := COALESCE((NEW.triage->>'victims_trapped')::integer, NEW.victims_trapped);
        END IF;
        IF NEW.triage ? 'location' THEN
            NEW.location := COALESCE(NEW.triage->>'location', NEW.location);
        END IF;
        IF NEW.triage ? 'summary' THEN
            NEW.summary := COALESCE(NEW.triage->>'summary', NEW.summary);
        END IF;
        IF NEW.triage ? 'required_resources' THEN
            NEW.required_resources := COALESCE(NEW.triage->'required_resources', NEW.required_resources);
        END IF;
        IF NEW.triage ? 'hazards_detected' THEN
            NEW.hazards_detected := COALESCE(NEW.triage->'hazards_detected', NEW.hazards_detected);
        END IF;
    END IF;

    -- Synchronize verification JSONB if null or updated from columns
    IF NEW.verification IS NULL THEN
        NEW.verification := jsonb_build_object(
            'confidence_score', NEW.confidence_score,
            'verified', NEW.verified,
            'urgency_confirmation', NEW.urgency_confirmation,
            'hallucination_detected', NEW.hallucination_detected,
            'verification_reasoning', NEW.verification_reasoning,
            'flagged_inconsistencies', NEW.flagged_inconsistencies,
            'recommended_action', NEW.recommended_action
        );
    ELSE
        -- If verification JSON was supplied directly, keep top-level columns in sync
        IF NEW.verification ? 'confidence_score' THEN
            NEW.confidence_score := COALESCE((NEW.verification->>'confidence_score')::integer, NEW.confidence_score);
        END IF;
        IF NEW.verification ? 'verified' THEN
            NEW.verified := COALESCE((NEW.verification->>'verified')::boolean, NEW.verified);
        END IF;
        IF NEW.verification ? 'urgency_confirmation' THEN
            NEW.urgency_confirmation := COALESCE(NEW.verification->>'urgency_confirmation', NEW.urgency_confirmation);
        END IF;
        IF NEW.verification ? 'hallucination_detected' THEN
            NEW.hallucination_detected := COALESCE((NEW.verification->>'hallucination_detected')::boolean, NEW.hallucination_detected);
        END IF;
        IF NEW.verification ? 'verification_reasoning' THEN
            NEW.verification_reasoning := COALESCE(NEW.verification->>'verification_reasoning', NEW.verification_reasoning);
        END IF;
        IF NEW.verification ? 'recommended_action' THEN
            NEW.recommended_action := COALESCE(NEW.verification->>'recommended_action', NEW.recommended_action);
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_ticket_json_fields ON public.emergency_tickets;
CREATE TRIGGER trg_sync_ticket_json_fields
BEFORE INSERT OR UPDATE ON public.emergency_tickets
FOR EACH ROW
EXECUTE FUNCTION public.sync_ticket_json_fields();

-- 7. RPC FUNCTIONS FOR BACKEND AND DASHBOARD

-- Function: get_system_stats()
-- Aggregates real-time incident counters matching /api/stats
CREATE OR REPLACE FUNCTION public.get_system_stats()
RETURNS JSONB AS $$
DECLARE
    stats JSONB;
BEGIN
    SELECT jsonb_build_object(
        'total_tickets', COUNT(*),
        'critical_tickets', COUNT(*) FILTER (WHERE urgency_level = 'CRITICAL'),
        'high_tickets', COUNT(*) FILTER (WHERE urgency_level = 'HIGH'),
        'medium_tickets', COUNT(*) FILTER (WHERE urgency_level = 'MEDIUM'),
        'low_tickets', COUNT(*) FILTER (WHERE urgency_level = 'LOW'),
        'total_victims_trapped', COALESCE(SUM(victims_trapped), 0),
        'dispatched_tickets', COUNT(*) FILTER (WHERE status IN ('DISPATCHED', 'EN_ROUTE')),
        'pending_tickets', COUNT(*) FILTER (WHERE status = 'PENDING'),
        'resolved_tickets', COUNT(*) FILTER (WHERE status = 'RESOLVED'),
        'average_confidence_score', COALESCE(ROUND(AVG(confidence_score)::numeric, 1), 0.0),
        'gemini_ai_configured', true
    )
    INTO stats
    FROM public.emergency_tickets;

    RETURN stats;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: update_ticket_status()
CREATE OR REPLACE FUNCTION public.update_ticket_status(
    p_ticket_id TEXT,
    p_status TEXT,
    p_notes TEXT DEFAULT NULL
)
RETURNS public.emergency_tickets AS $$
DECLARE
    updated_record public.emergency_tickets;
BEGIN
    UPDATE public.emergency_tickets
    SET 
        status = p_status,
        dispatcher_notes = COALESCE(p_notes, dispatcher_notes),
        updated_at = timezone('utc'::text, now())
    WHERE ticket_id = p_ticket_id
    RETURNING * INTO updated_record;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ticket with ID % not found.', p_ticket_id;
    END IF;

    RETURN updated_record;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 8. STORAGE BUCKET CONFIGURATION (Public access for incident media/audio)
INSERT INTO storage.buckets (id, name, public)
VALUES ('disaster-media', 'disaster-media', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- Storage public read policy
DO $$ BEGIN
    CREATE POLICY "Public Media Access" ON storage.objects
    FOR SELECT USING (bucket_id = 'disaster-media');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- Storage public insert policy for demo uploads
DO $$ BEGIN
    CREATE POLICY "Public Media Upload" ON storage.objects
    FOR INSERT WITH CHECK (bucket_id = 'disaster-media');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- 9. ROW LEVEL SECURITY (RLS) POLICIES
-- We enable RLS and add 100% permissive public demo policies so both anon and authenticated users
-- can read, insert, and update during the hackathon evaluation.
ALTER TABLE public.emergency_tickets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public Read All Tickets" ON public.emergency_tickets;
CREATE POLICY "Public Read All Tickets"
ON public.emergency_tickets FOR SELECT
TO anon, authenticated
USING (true);

DROP POLICY IF EXISTS "Public Insert Tickets" ON public.emergency_tickets;
CREATE POLICY "Public Insert Tickets"
ON public.emergency_tickets FOR INSERT
TO anon, authenticated
WITH CHECK (true);

DROP POLICY IF EXISTS "Public Update Tickets" ON public.emergency_tickets;
CREATE POLICY "Public Update Tickets"
ON public.emergency_tickets FOR UPDATE
TO anon, authenticated
USING (true)
WITH CHECK (true);

DROP POLICY IF EXISTS "Public Delete Tickets" ON public.emergency_tickets;
CREATE POLICY "Public Delete Tickets"
ON public.emergency_tickets FOR DELETE
TO anon, authenticated
USING (true);

-- (Optional) Disable RLS entirely to guarantee zero permission friction in demo:
ALTER TABLE public.emergency_tickets DISABLE ROW LEVEL SECURITY;

-- 10. REALISTIC RESCUE TICKETS SEED DATA
-- Ingests high-fidelity scenario tickets so visitors see immediate live emergency data.
INSERT INTO public.emergency_tickets (
    ticket_id,
    created_at,
    raw_text,
    source,
    reporter_name,
    contact_info,
    status,
    incident_type,
    urgency_level,
    victims_trapped,
    location,
    required_resources,
    summary,
    hazards_detected,
    confidence_score,
    verified,
    urgency_confirmation,
    hallucination_detected,
    verification_reasoning,
    flagged_inconsistencies,
    recommended_action,
    pipeline_latency_ms,
    engine_mode
) VALUES 
(
    'CRB-000001-DEMO',
    NOW() - INTERVAL '12 minutes',
    'Water levels rose 6 feet in 20 mins! Ground floor submerged, 4 elders and 2 infants trapped on terrace at 4th Cross, Rainbow Colony near Bellandur Lake, Bangalore. Water is touching electrical mains! Battery dying!',
    'Voice Transcript',
    'Suresh Kumar',
    '+91 98450 11234',
    'PENDING',
    'Flood',
    'CRITICAL',
    6,
    '4th Cross, Rainbow Colony near Bellandur Lake, Bangalore',
    '["Motorized Rescue Boats", "Evacuation Rafts", "Power Grid Disconnect Squad", "Paramedic Unit"]'::jsonb,
    'Urgent flood surge trapping 6 civilians (4 elderly, 2 infants) on rooftop with active electrical hazard.',
    '["Live electrical mains submerged in water", "Rapidly rising flash flood water", "Battery failure risk"]'::jsonb,
    98,
    true,
    'CRITICAL',
    false,
    'Verified against transcript. Landmark Bellandur Lake and 4th Cross verified. Trapped count 6 matches explicit caller counts (4 elders + 2 infants).',
    '[]'::jsonb,
    'Immediate boat dispatch and emergency Bescom transformer shutdown.',
    142.5,
    'gemini-2.5-flash'
),
(
    'CRB-000002-DEMO',
    NOW() - INTERVAL '28 minutes',
    'Dense chemical black smoke pouring from 3rd floor textiles godown at Industrial Area Phase 2, Peenya. 3 security guards trapped inside behind locked metal roll-down shutter! Flames spreading to fuel drums!',
    'Radio Call',
    'Station Commander 14',
    'Radio CH-4',
    'DISPATCHED',
    'Fire',
    'CRITICAL',
    3,
    'Industrial Area Phase 2, Peenya, Bangalore',
    '["Industrial Fire Ladder", "Breathing Apparatus (SCBA)", "Hydraulic Shutter Breaker", "Hazmat Unit"]'::jsonb,
    'Chemical textile fire in industrial zone with 3 security personnel trapped behind locked shutters near fuel drums.',
    '["Toxic dense black smoke", "Flammable solvent drums adjacent to fire", "Reinforced roll-down shutter"]'::jsonb,
    95,
    true,
    'CRITICAL',
    false,
    'Corroborated by official fire station radio dispatch. Location and 3 trapped personnel confirmed.',
    '[]'::jsonb,
    'Dispatch heavy hydraulic cutting squad and Hazmat water tenders.',
    128.0,
    'gemini-2.5-flash'
),
(
    'CRB-000003-DEMO',
    NOW() - INTERVAL '45 minutes',
    'Building column sheared after earth slip. 5 construction workers trapped under collapsed scaffolding near Metro Pillar 218, Outer Ring Road. Two bleeding heavily from head injuries, urgent trauma unit needed!',
    'SMS SOS',
    'Kavita R',
    '+91 98860 55432',
    'DISPATCHED',
    'Structural',
    'CRITICAL',
    5,
    'Near Metro Pillar 218, Outer Ring Road, Bangalore',
    '["Heavy Hydraulic Cutters", "ALS Trauma Ambulance", "Structural Stabilization Jacks", "Search & Rescue Canines"]'::jsonb,
    'Scaffolding and column structural collapse pinning 5 workers with severe traumatic bleeding near Metro Pillar 218.',
    '["Unstable shifting structural concrete", "Active earth slip", "Severe blood loss in victims"]'::jsonb,
    92,
    true,
    'CRITICAL',
    false,
    'Location tied to specific Metro Pillar 218 landmark. Severity corroborated by reported head injuries and crushed scaffolding.',
    '[]'::jsonb,
    'Deploy specialized urban search and rescue (USAR) team and 2 Advanced Life Support ambulances.',
    165.2,
    'gemini-2.5-flash'
),
(
    'CRB-000004-DEMO',
    NOW() - INTERVAL '1 hour 10 minutes',
    '72-year-old grandfather collapsed with sudden unilateral paralysis and severe chest pain. Roads are flooded with 2ft water, no standard ambulance can reach 12th Cross Indira Nagar near Water Tank. Oxygen saturation dropping.',
    'Web SOS',
    'Dr. Ananya Roy',
    '+91 98440 33211',
    'EN_ROUTE',
    'Medical',
    'HIGH',
    1,
    '12th Cross, Indira Nagar near Water Tank, Bangalore',
    '["High-Axle 4x4 Emergency Ambulance", "Portable Oxygen Concentrator", "Cardiac Paramedic Unit"]'::jsonb,
    'Suspected acute ischemic stroke / cardiac emergency in road-submerged residential zone with inaccessible roads.',
    '["Waterlogged approach road (2ft depth)", "Critical medical golden-hour window expiring"]'::jsonb,
    89,
    true,
    'HIGH',
    false,
    'Reported by verified physician on-site. Specific medical symptoms and waterlogged roadblock identified.',
    '[]'::jsonb,
    'Route high-axle emergency medical response vehicle via elevated bypass.',
    115.8,
    'gemini-2.5-flash'
),
(
    'CRB-000005-DEMO',
    NOW() - INTERVAL '2 hours',
    'Urban drainage overflow flooded basement carpark at 8th Main Koramangala. 3 vehicles floating, 2 maintenance staff isolated on generator platform. Water stabilized but no dry exit.',
    'Web SOS',
    'Society Secretary',
    '+91 98111 22334',
    'RESOLVED',
    'Flood',
    'MEDIUM',
    2,
    '8th Main, Koramangala, Bangalore',
    '["Inflatable Raft", "High-Volume De-watering Pump", "Submersible Utility Crew"]'::jsonb,
    'Basement parking submerged; 2 staff evacuated from generator platform. De-watering underway.',
    '["Submerged vehicles", "High-voltage generator proximity"]'::jsonb,
    91,
    true,
    'MEDIUM',
    false,
    'Evacuation confirmed complete by rescue team on scene. Water pumping active.',
    '[]'::jsonb,
    'Mark incident resolved; monitor basement drainage.',
    110.4,
    'gemini-2.5-flash'
)
ON CONFLICT (ticket_id) DO NOTHING;

-- Verification check query
SELECT ticket_id, incident_type, urgency_level, victims_trapped, status, confidence_score 
FROM public.emergency_tickets 
ORDER BY created_at DESC;

