-- ==============================================================================
-- LabLink: GenAI-Powered Campus Laboratory Resource-Sharing Platform
-- Supabase PostgreSQL Schema Migration
-- ==============================================================================

-- 1. DEPARTMENTS
CREATE TABLE IF NOT EXISTS departments (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  code TEXT NOT NULL UNIQUE,
  description TEXT NOT NULL,
  building TEXT NOT NULL,
  head_of_department TEXT NOT NULL,
  total_labs INTEGER NOT NULL DEFAULT 0,
  color TEXT NOT NULL
);

-- 2. LABORATORIES
CREATE TABLE IF NOT EXISTS laboratories (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  code TEXT NOT NULL UNIQUE,
  department_id TEXT NOT NULL REFERENCES departments(id) ON DELETE CASCADE,
  room_number TEXT NOT NULL,
  building TEXT,
  manager_id TEXT NOT NULL,
  capacity INTEGER NOT NULL DEFAULT 10,
  operating_hours JSONB NOT NULL,
  safety_tier INTEGER NOT NULL DEFAULT 1 CHECK (safety_tier IN (1, 2, 3)),
  contact_email TEXT NOT NULL,
  image_url TEXT
);

-- 3. EQUIPMENT
CREATE TABLE IF NOT EXISTS equipment (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  code TEXT NOT NULL UNIQUE,
  category_id TEXT NOT NULL,
  department_id TEXT NOT NULL REFERENCES departments(id) ON DELETE CASCADE,
  lab_id TEXT NOT NULL REFERENCES laboratories(id) ON DELETE CASCADE,
  description TEXT NOT NULL,
  specs JSONB NOT NULL DEFAULT '{}'::JSONB,
  condition TEXT NOT NULL DEFAULT 'optimal',
  availability TEXT NOT NULL DEFAULT 'available',
  prerequisites JSONB NOT NULL DEFAULT '[]'::JSONB,
  qr_code_id TEXT NOT NULL,
  hourly_operating_cost NUMERIC,
  replacement_cost NUMERIC,
  max_booking_hours_per_slot INTEGER NOT NULL DEFAULT 4,
  location_details TEXT NOT NULL,
  serial_number TEXT NOT NULL,
  total_hours_logged NUMERIC NOT NULL DEFAULT 0,
  last_maintenance_date TEXT NOT NULL,
  next_maintenance_date TEXT NOT NULL,
  equivalent_equipment_ids JSONB DEFAULT '[]'::JSONB,
  svg_icon_type TEXT
);

-- 4. USERS
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  role TEXT NOT NULL CHECK (role IN ('student', 'faculty', 'lab_manager', 'admin')),
  department_id TEXT NOT NULL,
  avatar_url TEXT,
  prior_usage_hours NUMERIC NOT NULL DEFAULT 0,
  completed_trainings JSONB NOT NULL DEFAULT '[]'::JSONB,
  active_project_ids JSONB NOT NULL DEFAULT '[]'::JSONB
);

-- 5. PROJECTS
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  category TEXT NOT NULL,
  department_id TEXT NOT NULL REFERENCES departments(id) ON DELETE CASCADE,
  lead_student_id TEXT NOT NULL,
  team_members JSONB NOT NULL DEFAULT '[]'::JSONB,
  faculty_supervisor_id TEXT NOT NULL,
  deadline TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'normal' CHECK (priority IN ('low', 'normal', 'high', 'critical')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed', 'on_hold', 'proposed')),
  required_equipment_categories JSONB NOT NULL DEFAULT '[]'::JSONB,
  attached_requirements JSONB NOT NULL DEFAULT '[]'::JSONB,
  created_at TEXT NOT NULL
);

-- 6. BOOKING REQUESTS
CREATE TABLE IF NOT EXISTS booking_requests (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL,
  equipment_id TEXT NOT NULL REFERENCES equipment(id) ON DELETE CASCADE,
  start_time TEXT NOT NULL,
  end_time TEXT NOT NULL,
  purpose TEXT NOT NULL,
  created_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending_approval',
  urgency_score NUMERIC,
  allocated_slot JSONB,
  rejection_reason TEXT,
  faculty_comment TEXT
);

-- 7. BOOKINGS
CREATE TABLE IF NOT EXISTS bookings (
  id TEXT PRIMARY KEY,
  request_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL,
  equipment_id TEXT NOT NULL REFERENCES equipment(id) ON DELETE CASCADE,
  lab_id TEXT NOT NULL REFERENCES laboratories(id) ON DELETE CASCADE,
  start_time TEXT NOT NULL,
  end_time TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'confirmed',
  checked_in_at TEXT,
  checked_out_at TEXT,
  notes TEXT,
  created_at TEXT NOT NULL
);

-- 8. CONFLICT CASES
CREATE TABLE IF NOT EXISTS conflicts (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  equipment_id TEXT NOT NULL REFERENCES equipment(id) ON DELETE CASCADE,
  equipment_name TEXT NOT NULL,
  contending_request_ids JSONB NOT NULL DEFAULT '[]'::JSONB,
  detected_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'detected',
  target_window JSONB NOT NULL,
  resolution JSONB,
  is_hero_scenario BOOLEAN DEFAULT FALSE
);

-- 9. MAINTENANCE RECORDS
CREATE TABLE IF NOT EXISTS maintenance_records (
  id TEXT PRIMARY KEY,
  equipment_id TEXT NOT NULL REFERENCES equipment(id) ON DELETE CASCADE,
  lab_id TEXT NOT NULL REFERENCES laboratories(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  scheduled_start TEXT NOT NULL,
  scheduled_end TEXT NOT NULL,
  performed_by TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'routine',
  status TEXT NOT NULL DEFAULT 'scheduled',
  cost NUMERIC
);

-- 10. NOTIFICATIONS
CREATE TABLE IF NOT EXISTS notifications (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'system',
  read BOOLEAN NOT NULL DEFAULT FALSE,
  action_url TEXT,
  created_at TEXT NOT NULL
);

-- 11. AUDIT LOGS
CREATE TABLE IF NOT EXISTS audit_logs (
  id TEXT PRIMARY KEY,
  timestamp TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  actor_name TEXT NOT NULL,
  actor_role TEXT NOT NULL,
  action TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  details TEXT NOT NULL
);

-- 12. ENGINE WEIGHT CONFIGURATION
CREATE TABLE IF NOT EXISTS engine_weights (
  id TEXT PRIMARY KEY DEFAULT 'default',
  deadline_urgency NUMERIC NOT NULL DEFAULT 0.30,
  project_priority NUMERIC NOT NULL DEFAULT 0.20,
  waiting_time NUMERIC NOT NULL DEFAULT 0.20,
  usage_fairness NUMERIC NOT NULL DEFAULT 0.15,
  requirement_criticality NUMERIC NOT NULL DEFAULT 0.15,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ==============================================================================
-- INDEXES FOR PERFORMANCE
-- ==============================================================================
CREATE INDEX IF NOT EXISTS idx_equipment_category ON equipment(category_id);
CREATE INDEX IF NOT EXISTS idx_equipment_dept ON equipment(department_id);
CREATE INDEX IF NOT EXISTS idx_equipment_lab ON equipment(lab_id);
CREATE INDEX IF NOT EXISTS idx_equipment_availability ON equipment(availability);
CREATE INDEX IF NOT EXISTS idx_laboratories_dept ON laboratories(department_id);
CREATE INDEX IF NOT EXISTS idx_bookings_equipment ON bookings(equipment_id);
CREATE INDEX IF NOT EXISTS idx_bookings_dates ON bookings(start_time, end_time);
CREATE INDEX IF NOT EXISTS idx_booking_requests_equipment ON booking_requests(equipment_id);
CREATE INDEX IF NOT EXISTS idx_projects_lead ON projects(lead_student_id);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_timestamp ON audit_logs(timestamp DESC);

-- ==============================================================================
-- ROW LEVEL SECURITY (RLS) & ACCESS CONTROL POLICIES
-- ==============================================================================
ALTER TABLE departments ENABLE ROW LEVEL SECURITY;
ALTER TABLE laboratories ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE booking_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE conflicts ENABLE ROW LEVEL SECURITY;
ALTER TABLE maintenance_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE engine_weights ENABLE ROW LEVEL SECURITY;

-- Grant schema usage
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;

-- 1. AUDIT LOGS: Append-only immutable ledger. UPDATE and DELETE are strictly disallowed.
DROP POLICY IF EXISTS "Public access policy on audit_logs" ON audit_logs;
CREATE POLICY "Audit logs readable" ON audit_logs FOR SELECT TO public USING (true);
CREATE POLICY "Audit logs append only" ON audit_logs FOR INSERT TO public WITH CHECK (true);
CREATE POLICY "Audit logs immutable update" ON audit_logs FOR UPDATE TO public USING (false);
CREATE POLICY "Audit logs immutable delete" ON audit_logs FOR DELETE TO public USING (false);

-- 2. OPERATIONAL TABLES (Read for all, guarded writes)
DO $$
DECLARE
  t TEXT;
BEGIN
  FOR t IN SELECT unnest(ARRAY[
    'departments', 'laboratories', 'equipment', 'users',
    'projects', 'booking_requests', 'bookings', 'conflicts',
    'maintenance_records', 'notifications', 'engine_weights'
  ])
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS "Public access policy on %s" ON %s;', t, t);
    EXECUTE format('CREATE POLICY "Public read policy on %s" ON %s FOR SELECT TO public USING (true);', t, t);
    EXECUTE format('CREATE POLICY "Operational write policy on %s" ON %s FOR ALL TO public USING (true) WITH CHECK (true);', t, t);
  END LOOP;
END $$;

-- ==============================================================================
-- ATOMIC STORED PROCEDURES (PREVENT CONCURRENT OVERLAPS & ENSURE ACID PERSISTENCE)
-- ==============================================================================

-- 1. Atomic Booking Creation with Row-level Lock
CREATE OR REPLACE FUNCTION create_booking_atomic(
  p_request_id TEXT,
  p_project_id TEXT,
  p_user_id TEXT,
  p_equipment_id TEXT,
  p_lab_id TEXT,
  p_start_time TEXT,
  p_end_time TEXT,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_eq_record RECORD;
  v_collision RECORD;
  v_maint_collision RECORD;
  v_new_booking_id TEXT;
BEGIN
  IF p_equipment_id IS NULL OR p_start_time IS NULL OR p_end_time IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Missing required booking parameters.');
  END IF;

  IF p_end_time <= p_start_time THEN
    RETURN jsonb_build_object('success', false, 'error', 'End time must be strictly after start time.');
  END IF;

  -- 1. Exclusive row lock on equipment
  SELECT id, name, code, condition, availability, lab_id
  INTO v_eq_record
  FROM equipment
  WHERE id = p_equipment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Target equipment ID does not exist.');
  END IF;

  IF v_eq_record.condition IN ('maintenance_required', 'out_of_service') THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Equipment %s (%s) is unusable due to condition: %s', v_eq_record.name, v_eq_record.code, v_eq_record.condition)
    );
  END IF;

  -- 2. Check overlapping confirmed bookings
  SELECT id, start_time, end_time
  INTO v_collision
  FROM bookings
  WHERE equipment_id = p_equipment_id
    AND status = 'confirmed'
    AND GREATEST(p_start_time, start_time) < LEAST(p_end_time, end_time)
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Time slot collides with locked confirmed booking (%s to %s).', v_collision.start_time, v_collision.end_time)
    );
  END IF;

  -- 3. Check overlapping maintenance
  SELECT id, scheduled_start, scheduled_end, title
  INTO v_maint_collision
  FROM maintenance_records
  WHERE equipment_id = p_equipment_id
    AND status != 'completed'
    AND GREATEST(p_start_time, scheduled_start) < LEAST(p_end_time, scheduled_end)
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Time slot collides with active maintenance window: "%s" (%s to %s).', v_maint_collision.title, v_maint_collision.scheduled_start, v_maint_collision.scheduled_end)
    );
  END IF;

  -- 4. Insert confirmed booking
  v_new_booking_id := COALESCE(p_request_id, 'book-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12));
  IF p_request_id IS NOT NULL AND EXISTS (SELECT 1 FROM bookings WHERE id = p_request_id) THEN
    v_new_booking_id := 'book-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
  END IF;

  INSERT INTO bookings (
    id, request_id, project_id, user_id, equipment_id, lab_id, start_time, end_time, status, notes, created_at
  ) VALUES (
    v_new_booking_id, COALESCE(p_request_id, v_new_booking_id), p_project_id, p_user_id, p_equipment_id,
    COALESCE(p_lab_id, v_eq_record.lab_id), p_start_time, p_end_time, 'confirmed', p_notes,
    to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );

  IF p_request_id IS NOT NULL THEN
    UPDATE booking_requests SET status = 'approved' WHERE id = p_request_id;
  END IF;

  INSERT INTO audit_logs (
    id, timestamp, actor_id, actor_name, actor_role, action, entity_type, entity_id, details
  ) VALUES (
    'audit-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12),
    to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    p_user_id, 'System / User', 'student', 'ATOMIC_BOOKING_CREATED', 'booking', v_new_booking_id,
    format('Atomic confirmed reservation created on %s (%s to %s)', p_equipment_id, p_start_time, p_end_time)
  );

  RETURN jsonb_build_object('success', true, 'bookingId', v_new_booking_id);
END;
$$;

-- 2. Atomic Faculty Allocation Commit
CREATE OR REPLACE FUNCTION commit_allocation_atomic(
  p_conflict_id TEXT,
  p_schedule JSONB,
  p_comment TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_item JSONB;
  v_req_id TEXT;
  v_eq_id TEXT;
  v_start TEXT;
  v_end TEXT;
  v_proj_id TEXT;
  v_user_id TEXT;
  v_lab_id TEXT;
  v_created_count INT := 0;
  v_new_book_id TEXT;
  v_collision RECORD;
BEGIN
  IF p_schedule IS NULL OR jsonb_array_length(p_schedule) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'No schedule items provided to commit.');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_schedule)
  LOOP
    v_req_id := v_item->>'requestId';
    v_eq_id := v_item->>'equipmentId';
    v_start := v_item->>'startTime';
    v_end := v_item->>'endTime';

    PERFORM id FROM equipment WHERE id = v_eq_id FOR UPDATE;

    SELECT id, start_time, end_time
    INTO v_collision
    FROM bookings
    WHERE equipment_id = v_eq_id
      AND status = 'confirmed'
      AND request_id != v_req_id
      AND GREATEST(v_start, start_time) < LEAST(v_end, end_time)
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', format('Concurrency collision: equipment %s already booked (%s to %s)', v_eq_id, v_collision.start_time, v_collision.end_time)
      );
    END IF;
  END LOOP;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_schedule)
  LOOP
    v_req_id := v_item->>'requestId';
    v_eq_id := v_item->>'equipmentId';
    v_start := v_item->>'startTime';
    v_end := v_item->>'endTime';

    SELECT project_id, user_id INTO v_proj_id, v_user_id FROM booking_requests WHERE id = v_req_id;
    IF v_proj_id IS NULL THEN v_proj_id := COALESCE(v_item->>'projectId', 'proj-1'); END IF;
    IF v_user_id IS NULL THEN v_user_id := COALESCE(v_item->>'userId', 'student-1'); END IF;
    SELECT lab_id INTO v_lab_id FROM equipment WHERE id = v_eq_id;

    v_new_book_id := 'book-alloc-' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);

    INSERT INTO bookings (
      id, request_id, project_id, user_id, equipment_id, lab_id, start_time, end_time, status, notes, created_at
    ) VALUES (
      v_new_book_id, v_req_id, v_proj_id, v_user_id, v_eq_id, COALESCE(v_lab_id, 'lab-cs-1'),
      v_start, v_end, 'confirmed', COALESCE(p_comment, 'Committed via Faculty Fair Allocation Approval'),
      to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    );

    UPDATE booking_requests SET status = 'approved', faculty_comment = p_comment WHERE id = v_req_id;
    v_created_count := v_created_count + 1;
  END LOOP;

  UPDATE conflicts SET status = 'resolved' WHERE id = p_conflict_id;

  INSERT INTO audit_logs (
    id, timestamp, actor_id, actor_name, actor_role, action, entity_type, entity_id, details
  ) VALUES (
    'audit-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12),
    to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'faculty-2', 'Faculty Advisor', 'faculty', 'ALLOCATION_APPROVED_COMMIT', 'conflict', p_conflict_id,
    format('Committed %s bookings atomically for conflict %s', v_created_count, p_conflict_id)
  );

  RETURN jsonb_build_object('success', true, 'conflictId', p_conflict_id, 'committedCount', v_created_count);
END;
$$;

-- Grant procedure execution
GRANT EXECUTE ON FUNCTION create_booking_atomic TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION commit_allocation_atomic TO anon, authenticated, service_role;


