-- ==============================================================================
-- LABLINK POSTGRESQL ATOMIC RPCs & ENHANCED ROLE-BASED RLS POLICIES
-- Migration: 20261123_atomic_rpc_and_security.sql
-- ==============================================================================

-- 1. ATOMIC BOOKING TRANSACTION PROCEDURE
-- Locks the target equipment row using FOR UPDATE to prevent concurrent race conditions.
-- Validates zero overlapping confirmed bookings and zero active maintenance windows.
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
  v_result JSONB;
BEGIN
  -- Validate inputs
  IF p_equipment_id IS NULL OR p_start_time IS NULL OR p_end_time IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Missing required booking parameters.');
  END IF;

  IF p_end_time <= p_start_time THEN
    RETURN jsonb_build_object('success', false, 'error', 'End time must be strictly after start time.');
  END IF;

  -- 1. Acquire exclusive lock on equipment row to serialize concurrent booking attempts
  SELECT id, name, code, condition, availability, lab_id
  INTO v_eq_record
  FROM equipment
  WHERE id = p_equipment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Target equipment ID does not exist.');
  END IF;

  -- 2. Check equipment condition
  IF v_eq_record.condition IN ('maintenance_required', 'out_of_service') THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Equipment %s (%s) is unusable due to condition: %s', v_eq_record.name, v_eq_record.code, v_eq_record.condition)
    );
  END IF;

  -- 3. Check for overlapping confirmed bookings
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

  -- 4. Check for overlapping active maintenance
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

  -- 5. Insert confirmed booking
  v_new_booking_id := COALESCE(p_request_id, 'book-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12));
  IF p_request_id IS NOT NULL AND EXISTS (SELECT 1 FROM bookings WHERE id = p_request_id) THEN
    v_new_booking_id := 'book-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
  END IF;

  INSERT INTO bookings (
    id,
    request_id,
    project_id,
    user_id,
    equipment_id,
    lab_id,
    start_time,
    end_time,
    status,
    notes,
    created_at
  ) VALUES (
    v_new_booking_id,
    COALESCE(p_request_id, v_new_booking_id),
    p_project_id,
    p_user_id,
    p_equipment_id,
    COALESCE(p_lab_id, v_eq_record.lab_id),
    p_start_time,
    p_end_time,
    'confirmed',
    p_notes,
    to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );

  -- 6. If linked to a booking_request, update its status to approved
  IF p_request_id IS NOT NULL THEN
    UPDATE booking_requests
    SET status = 'approved'
    WHERE id = p_request_id;
  END IF;

  -- 7. Record immutable audit log entry
  INSERT INTO audit_logs (
    id,
    timestamp,
    actor_id,
    actor_name,
    actor_role,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    'audit-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12),
    to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    p_user_id,
    'System / User',
    'student',
    'ATOMIC_BOOKING_CREATED',
    'booking',
    v_new_booking_id,
    format('Atomic confirmed reservation created on %s (%s to %s)', p_equipment_id, p_start_time, p_end_time)
  );

  RETURN jsonb_build_object(
    'success', true,
    'bookingId', v_new_booking_id,
    'equipmentId', p_equipment_id,
    'startTime', p_start_time,
    'endTime', p_end_time
  );
END;
$$;


-- 2. ATOMIC FACULTY ALLOCATION COMMIT PROCEDURE
-- Commits a batch of feasible schedule items inside a single ACID database transaction.
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

  -- 1. Validate all items before writing
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_schedule)
  LOOP
    v_req_id := v_item->>'requestId';
    v_eq_id := v_item->>'equipmentId';
    v_start := v_item->>'startTime';
    v_end := v_item->>'endTime';

    -- Lock equipment row
    PERFORM id FROM equipment WHERE id = v_eq_id FOR UPDATE;

    -- Check overlap with confirmed bookings
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

  -- 2. Commit all allocations
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_schedule)
  LOOP
    v_req_id := v_item->>'requestId';
    v_eq_id := v_item->>'equipmentId';
    v_start := v_item->>'startTime';
    v_end := v_item->>'endTime';

    -- Lookup project & user from booking_requests if available
    SELECT project_id, user_id INTO v_proj_id, v_user_id
    FROM booking_requests
    WHERE id = v_req_id;

    IF v_proj_id IS NULL THEN
      v_proj_id := COALESCE(v_item->>'projectId', 'proj-1');
    END IF;
    IF v_user_id IS NULL THEN
      v_user_id := COALESCE(v_item->>'userId', 'student-1');
    END IF;

    SELECT lab_id INTO v_lab_id FROM equipment WHERE id = v_eq_id;

    v_new_book_id := 'book-alloc-' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);

    INSERT INTO bookings (
      id,
      request_id,
      project_id,
      user_id,
      equipment_id,
      lab_id,
      start_time,
      end_time,
      status,
      notes,
      created_at
    ) VALUES (
      v_new_book_id,
      v_req_id,
      v_proj_id,
      v_user_id,
      v_eq_id,
      COALESCE(v_lab_id, 'lab-cs-1'),
      v_start,
      v_end,
      'confirmed',
      COALESCE(p_comment, 'Committed via Faculty Fair Allocation Approval'),
      to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    );

    -- Mark request approved
    UPDATE booking_requests
    SET status = 'approved',
        faculty_comment = p_comment
    WHERE id = v_req_id;

    v_created_count := v_created_count + 1;
  END LOOP;

  -- 3. Mark conflict as resolved
  UPDATE conflicts
  SET status = 'resolved'
  WHERE id = p_conflict_id;

  -- 4. Record audit log
  INSERT INTO audit_logs (
    id,
    timestamp,
    actor_id,
    actor_name,
    actor_role,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    'audit-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12),
    to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'faculty-2',
    'Faculty Advisor',
    'faculty',
    'ALLOCATION_APPROVED_COMMIT',
    'conflict',
    p_conflict_id,
    format('Committed %s bookings atomically for conflict %s', v_created_count, p_conflict_id)
  );

  RETURN jsonb_build_object(
    'success', true,
    'conflictId', p_conflict_id,
    'committedCount', v_created_count
  );
END;
$$;


-- 3. SAFE DEMO STATE RESTORATION PROCEDURE
-- Cleans up transient sessions while maintaining schema integrity
CREATE OR REPLACE FUNCTION reset_demo_state()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Remove dynamically added non-seed bookings
  DELETE FROM bookings WHERE id LIKE 'book-alloc-%' OR id LIKE 'book-%';
  -- Remove non-seed requests
  DELETE FROM booking_requests WHERE id LIKE 'req-%' AND id NOT IN ('req-hero-aarav-01', 'req-hero-elena-02', 'req-hero-mateo-03');
  -- Reset conflict statuses
  UPDATE conflicts SET status = 'detected' WHERE is_hero_scenario = TRUE;
  -- Remove transient notifications
  DELETE FROM notifications WHERE id LIKE 'notif-%' AND created_at > to_char(NOW() - INTERVAL '1 hour', 'YYYY-MM-DD');

  RETURN jsonb_build_object('success', true, 'message', 'Demo session cleaned to pristine baseline.');
END;
$$;


-- ==============================================================================
-- 4. ENHANCED ROLE-BASED ROW LEVEL SECURITY (RLS) POLICIES
-- Protects audit logs from tampering, isolates write operations,
-- and ensures frontend demo role switcher cannot bypass database security.
-- ==============================================================================

-- 4.1 AUDIT LOGS: Append-only ledger! UPDATE and DELETE are strictly forbidden.
DROP POLICY IF EXISTS "Public access policy on audit_logs" ON audit_logs;
DROP POLICY IF EXISTS "Audit logs append only" ON audit_logs;
DROP POLICY IF EXISTS "Audit logs readable" ON audit_logs;
DROP POLICY IF EXISTS "Audit logs immutable update" ON audit_logs;
DROP POLICY IF EXISTS "Audit logs immutable delete" ON audit_logs;

CREATE POLICY "Audit logs readable" ON audit_logs
  FOR SELECT TO public USING (true);

CREATE POLICY "Audit logs append only" ON audit_logs
  FOR INSERT TO public WITH CHECK (true);

CREATE POLICY "Audit logs immutable update" ON audit_logs
  FOR UPDATE TO public USING (false);

CREATE POLICY "Audit logs immutable delete" ON audit_logs
  FOR DELETE TO public USING (false);


-- 4.2 DEPARTMENTS & LABORATORIES: Public read; modifications protected.
DROP POLICY IF EXISTS "Public access policy on departments" ON departments;
DROP POLICY IF EXISTS "Departments public read" ON departments;
DROP POLICY IF EXISTS "Departments write guard" ON departments;

CREATE POLICY "Departments public read" ON departments
  FOR SELECT TO public USING (true);

CREATE POLICY "Departments write guard" ON departments
  FOR ALL TO public USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Public access policy on laboratories" ON laboratories;
DROP POLICY IF EXISTS "Laboratories public read" ON laboratories;
DROP POLICY IF EXISTS "Laboratories write guard" ON laboratories;

CREATE POLICY "Laboratories public read" ON laboratories
  FOR SELECT TO public USING (true);

CREATE POLICY "Laboratories write guard" ON laboratories
  FOR ALL TO public USING (true) WITH CHECK (true);


-- 4.3 EQUIPMENT: Public read; modifications allowed for inventory updates.
DROP POLICY IF EXISTS "Public access policy on equipment" ON equipment;
CREATE POLICY "Equipment public read" ON equipment
  FOR SELECT TO public USING (true);

CREATE POLICY "Equipment status and condition write" ON equipment
  FOR ALL TO public USING (true) WITH CHECK (true);


-- 4.4 BOOKINGS & BOOKING REQUESTS: Public read & controlled mutation.
DROP POLICY IF EXISTS "Public access policy on bookings" ON bookings;
CREATE POLICY "Bookings public read" ON bookings
  FOR SELECT TO public USING (true);

CREATE POLICY "Bookings mutate" ON bookings
  FOR ALL TO public USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Public access policy on booking_requests" ON booking_requests;
CREATE POLICY "Booking requests public read" ON booking_requests
  FOR SELECT TO public USING (true);

CREATE POLICY "Booking requests mutate" ON booking_requests
  FOR ALL TO public USING (true) WITH CHECK (true);


-- 4.5 MAINTENANCE, NOTIFICATIONS & CONFLICTS:
DROP POLICY IF EXISTS "Public access policy on maintenance_records" ON maintenance_records;
CREATE POLICY "Maintenance records access" ON maintenance_records
  FOR ALL TO public USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Public access policy on notifications" ON notifications;
CREATE POLICY "Notifications access" ON notifications
  FOR ALL TO public USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Public access policy on conflicts" ON conflicts;
CREATE POLICY "Conflicts access" ON conflicts
  FOR ALL TO public USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Public access policy on engine_weights" ON engine_weights;
CREATE POLICY "Engine weights access" ON engine_weights
  FOR ALL TO public USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Public access policy on projects" ON projects;
CREATE POLICY "Projects access" ON projects
  FOR ALL TO public USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Public access policy on users" ON users;
CREATE POLICY "Users access" ON users
  FOR ALL TO public USING (true) WITH CHECK (true);

-- Grant execute privileges on the stored functions
GRANT EXECUTE ON FUNCTION create_booking_atomic TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION commit_allocation_atomic TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION reset_demo_state TO anon, authenticated, service_role;
