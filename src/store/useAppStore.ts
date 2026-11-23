import { create } from 'zustand';
import {
  Role,
  User,
  Department,
  Laboratory,
  Equipment,
  Project,
  Booking,
  BookingRequest,
  ConflictCase,
  MaintenanceRecord,
  Notification,
  AuditLogEntry,
  EngineWeightConfig,
  AllocationResult,
  WaitlistEntry,
} from '../types';
import { StorageService } from './storage';
import { DEFAULT_ENGINE_WEIGHTS } from '../data/seedData';

export interface AppState {
  // Role & Demo Identity
  currentRole: Role;
  currentUser: User;
  isDemoMode: boolean;

  // Domain Data
  departments: Department[];
  laboratories: Laboratory[];
  equipment: Equipment[];
  users: User[];
  projects: Project[];
  bookings: Booking[];
  bookingRequests: BookingRequest[];
  conflicts: ConflictCase[];
  maintenanceRecords: MaintenanceRecord[];
  notifications: Notification[];
  auditLogs: AuditLogEntry[];
  waitlist: WaitlistEntry[];
  engineWeights: EngineWeightConfig;

  // Indexed Lookups for O(1) reads
  equipmentMap: Record<string, Equipment>;
  labMap: Record<string, Laboratory>;
  deptMap: Record<string, Department>;
  userMap: Record<string, User>;
  projectMap: Record<string, Project>;

  // Guided Demo Tour State
  guidedTourOpen: boolean;
  guidedTourStep: number;

  // Actions
  setRole: (role: Role) => void;
  resetDemoData: () => void;
  setEngineWeights: (weights: EngineWeightConfig) => void;

  // Project Actions
  createProject: (project: Omit<Project, 'id' | 'createdAt'>) => Project;
  updateProject: (id: string, updates: Partial<Project>) => void;
  deleteProject: (id: string) => void;

  // Equipment Actions (Lab Manager / Admin guard)
  addEquipment: (eq: Omit<Equipment, 'id'>) => boolean;
  updateEquipment: (id: string, updates: Partial<Equipment>) => boolean;
  deleteEquipment: (id: string) => boolean;

  // Booking Actions
  createBookingRequest: (req: Omit<BookingRequest, 'id' | 'createdAt' | 'status'>) => BookingRequest;
  cancelBooking: (bookingId: string) => boolean;
  rescheduleBooking: (bookingId: string, newStart: string, newEnd: string) => boolean;

  // Faculty Actions (Faculty guard)
  approveAllocation: (conflictId: string, comment?: string) => boolean;
  rejectAllocation: (conflictId: string, reason: string) => boolean;
  modifyAllocation: (conflictId: string, updatedSchedule: AllocationResult['feasibleSchedule'], comment?: string) => boolean;

  // Maintenance Actions (Lab Manager / Admin guard)
  createMaintenanceRecord: (record: Omit<MaintenanceRecord, 'id'>) => boolean;
  updateMaintenanceStatus: (recordId: string, status: MaintenanceRecord['status']) => boolean;

  // Notifications & Audit
  markNotificationRead: (id: string) => void;
  markAllNotificationsRead: () => void;
  addAuditLog: (action: string, entityType: AuditLogEntry['entityType'], entityId: string, details: string) => void;

  // Guided Tour
  openGuidedTour: () => void;
  closeGuidedTour: () => void;
  nextTourStep: () => void;
  prevTourStep: () => void;
}

function buildLookups(state: Pick<AppState, 'equipment' | 'laboratories' | 'departments' | 'users' | 'projects'>) {
  const equipmentMap: Record<string, Equipment> = {};
  state.equipment.forEach((e) => (equipmentMap[e.id] = e));

  const labMap: Record<string, Laboratory> = {};
  state.laboratories.forEach((l) => (labMap[l.id] = l));

  const deptMap: Record<string, Department> = {};
  state.departments.forEach((d) => (deptMap[d.id] = d));

  const userMap: Record<string, User> = {};
  state.users.forEach((u) => (userMap[u.id] = u));

  const projectMap: Record<string, Project> = {};
  state.projects.forEach((p) => (projectMap[p.id] = p));

  return { equipmentMap, labMap, deptMap, userMap, projectMap };
}

function selectDefaultUserForRole(role: Role, users: User[]): User {
  switch (role) {
    case 'student':
      return users.find((u) => u.id === 'student-1') || users.find((u) => u.role === 'student')!;
    case 'faculty':
      return users.find((u) => u.id === 'faculty-2') || users.find((u) => u.role === 'faculty')!;
    case 'lab_manager':
      return users.find((u) => u.id === 'mgr-1') || users.find((u) => u.role === 'lab_manager')!;
    case 'admin':
      return users.find((u) => u.id === 'admin-1') || users.find((u) => u.role === 'admin')!;
  }
}

export const useAppStore = create<AppState>((set, get) => {
  const initial = StorageService.load();
  const lookups = buildLookups({
    equipment: initial.equipment,
    laboratories: initial.laboratories,
    departments: initial.departments,
    users: initial.users,
    projects: initial.projects,
  });

  const defaultUser = selectDefaultUserForRole('student', initial.users);

  return {
    currentRole: 'student',
    currentUser: defaultUser,
    isDemoMode: true,

    departments: initial.departments,
    laboratories: initial.laboratories,
    equipment: initial.equipment,
    users: initial.users,
    projects: initial.projects,
    bookings: initial.bookings,
    bookingRequests: initial.bookingRequests,
    conflicts: initial.conflicts,
    maintenanceRecords: initial.maintenanceRecords,
    notifications: initial.notifications,
    auditLogs: initial.auditLogs,
    waitlist: [],
    engineWeights: initial.engineWeights || DEFAULT_ENGINE_WEIGHTS,

    ...lookups,

    guidedTourOpen: false,
    guidedTourStep: 0,

    setRole: (role: Role) => {
      const state = get();
      const newUser = selectDefaultUserForRole(role, state.users);
      set({ currentRole: role, currentUser: newUser });
    },

    resetDemoData: () => {
      const fresh = StorageService.reset();
      const freshLookups = buildLookups({
        equipment: fresh.equipment,
        laboratories: fresh.laboratories,
        departments: fresh.departments,
        users: fresh.users,
        projects: fresh.projects,
      });
      const freshUser = selectDefaultUserForRole('student', fresh.users);
      set({
        ...fresh,
        currentRole: 'student',
        currentUser: freshUser,
        waitlist: [],
        ...freshLookups,
        guidedTourOpen: false,
        guidedTourStep: 0,
      });
    },

    setEngineWeights: (weights: EngineWeightConfig) => {
      set({ engineWeights: weights });
      const state = get();
      StorageService.save({
        departments: state.departments,
        laboratories: state.laboratories,
        equipment: state.equipment,
        users: state.users,
        projects: state.projects,
        bookings: state.bookings,
        bookingRequests: state.bookingRequests,
        conflicts: state.conflicts,
        maintenanceRecords: state.maintenanceRecords,
        notifications: state.notifications,
        auditLogs: state.auditLogs,
        engineWeights: weights,
      });
    },

    createProject: (projData) => {
      const state = get();
      const newId = `proj-${Date.now()}`;
      const newProj: Project = {
        ...projData,
        id: newId,
        createdAt: new Date().toISOString(),
      };
      const updatedProjects = [newProj, ...state.projects];
      set({
        projects: updatedProjects,
        projectMap: { ...state.projectMap, [newId]: newProj },
      });
      get().addAuditLog('PROJECT_CREATED', 'project', newId, `Created project "${newProj.title}"`);
      return newProj;
    },

    updateProject: (id, updates) => {
      const state = get();
      const updated = state.projects.map((p) => (p.id === id ? { ...p, ...updates } : p));
      const updatedObj = updated.find((p) => p.id === id);
      if (!updatedObj) return;
      set({
        projects: updated,
        projectMap: { ...state.projectMap, [id]: updatedObj },
      });
      get().addAuditLog('PROJECT_UPDATED', 'project', id, `Updated project "${updatedObj.title}"`);
    },

    deleteProject: (id) => {
      const state = get();
      const updated = state.projects.filter((p) => p.id !== id);
      const newMap = { ...state.projectMap };
      delete newMap[id];
      set({ projects: updated, projectMap: newMap });
      get().addAuditLog('PROJECT_DELETED', 'project', id, `Deleted project id ${id}`);
    },

    addEquipment: (eqData) => {
      const state = get();
      if (state.currentRole !== 'lab_manager' && state.currentRole !== 'admin') {
        console.warn('Unauthorized: Only Lab Managers or Admins can add equipment.');
        return false;
      }
      const newId = `eq-${Date.now()}`;
      const newEq: Equipment = {
        ...eqData,
        id: newId,
      };
      const updatedList = [newEq, ...state.equipment];
      set({
        equipment: updatedList,
        equipmentMap: { ...state.equipmentMap, [newId]: newEq },
      });
      get().addAuditLog('EQUIPMENT_CREATED', 'equipment', newId, `Added equipment unit "${newEq.name}"`);
      return true;
    },

    updateEquipment: (id, updates) => {
      const state = get();
      if (state.currentRole !== 'lab_manager' && state.currentRole !== 'admin') {
        console.warn('Unauthorized: Only Lab Managers or Admins can modify equipment.');
        return false;
      }
      const updated = state.equipment.map((e) => (e.id === id ? { ...e, ...updates } : e));
      const target = updated.find((e) => e.id === id);
      if (!target) return false;
      set({
        equipment: updated,
        equipmentMap: { ...state.equipmentMap, [id]: target },
      });
      get().addAuditLog('EQUIPMENT_UPDATED', 'equipment', id, `Updated equipment ${target.name} (${target.code})`);
      return true;
    },

    deleteEquipment: (id) => {
      const state = get();
      if (state.currentRole !== 'admin') {
        console.warn('Unauthorized: Only Admins can delete equipment.');
        return false;
      }
      const updated = state.equipment.filter((e) => e.id !== id);
      const newMap = { ...state.equipmentMap };
      delete newMap[id];
      set({ equipment: updated, equipmentMap: newMap });
      get().addAuditLog('EQUIPMENT_DELETED', 'equipment', id, `Deleted equipment ${id}`);
      return true;
    },

    createBookingRequest: (reqData) => {
      const state = get();
      const newId = `req-${Date.now()}`;
      const newReq: BookingRequest = {
        ...reqData,
        id: newId,
        createdAt: new Date().toISOString(),
        status: 'pending_approval',
      };
      const updatedRequests = [newReq, ...state.bookingRequests];
      set({ bookingRequests: updatedRequests });
      get().addAuditLog('BOOKING_REQUEST_CREATED', 'booking', newId, `Requested slot for ${reqData.equipmentId}`);
      return newReq;
    },

    cancelBooking: (bookingId) => {
      const state = get();
      const target = state.bookings.find((b) => b.id === bookingId);
      if (!target) return false;

      // Update booking status
      const updatedBookings = state.bookings.map((b) =>
        b.id === bookingId ? { ...b, status: 'cancelled' as const } : b
      );

      // Check if there is an active waitlist entry for this equipment
      const matchingWaitlist = state.waitlist.filter(
        (w) => w.equipmentId === target.equipmentId && w.status === 'active'
      ).sort((a, b) => b.priorityScore - a.priorityScore);

      let updatedWaitlist = state.waitlist;
      let promotedNotif: Notification | null = null;

      if (matchingWaitlist.length > 0) {
        const topCandidate = matchingWaitlist[0];
        updatedWaitlist = state.waitlist.map((w) =>
          w.id === topCandidate.id ? { ...w, status: 'promoted' as const } : w
        );

        // Create new confirmed booking from waitlist promotion
        const newBookingId = `book-promoted-${Date.now()}`;
        const promotedBooking: Booking = {
          id: newBookingId,
          requestId: topCandidate.bookingRequestId,
          projectId: 'proj-1',
          userId: 'student-2',
          equipmentId: topCandidate.equipmentId,
          labId: target.labId,
          startTime: topCandidate.preferredStartTime,
          endTime: topCandidate.preferredEndTime,
          status: 'confirmed',
          notes: 'Promoted automatically from waitlist after cancellation.',
          createdAt: new Date().toISOString(),
        };
        updatedBookings.push(promotedBooking);

        promotedNotif = {
          id: `notif-${Date.now()}`,
          userId: 'student-2',
          title: 'Slot Available! Waitlist Promotion Successful',
          message: `Your waitlisted slot for ${target.equipmentId} has been confirmed due to a cancellation.`,
          type: 'booking',
          read: false,
          createdAt: new Date().toISOString(),
        };
      }

      set({
        bookings: updatedBookings,
        waitlist: updatedWaitlist,
        notifications: promotedNotif
          ? [promotedNotif, ...state.notifications]
          : state.notifications,
      });

      get().addAuditLog('BOOKING_CANCELLED', 'booking', bookingId, `Cancelled booking ${bookingId}`);
      return true;
    },

    rescheduleBooking: (bookingId, newStart, newEnd) => {
      const state = get();
      const updated = state.bookings.map((b) =>
        b.id === bookingId ? { ...b, startTime: newStart, endTime: newEnd } : b
      );
      set({ bookings: updated });
      get().addAuditLog('BOOKING_RESCHEDULED', 'booking', bookingId, `Shifted to ${newStart} - ${newEnd}`);
      return true;
    },

    approveAllocation: (conflictId, comment) => {
      const state = get();
      if (state.currentRole !== 'faculty') {
        console.warn('Unauthorized: Only Faculty can approve allocations.');
        return false;
      }
      const conflict = state.conflicts.find((c) => c.id === conflictId);
      if (!conflict || !conflict.resolution) return false;

      // Commit feasible schedule atomically
      const newBookings: Booking[] = conflict.resolution.feasibleSchedule.map((slot, idx) => ({
        id: `book-alloc-${Date.now()}-${idx}`,
        requestId: slot.requestId,
        projectId: 'proj-1',
        userId: 'student-1',
        equipmentId: slot.equipmentId,
        labId: 'lab-cs-1',
        startTime: slot.startTime,
        endTime: slot.endTime,
        status: 'confirmed',
        notes: `Committed via Faculty Approval (${comment || 'Fair Allocation Approved'})`,
        createdAt: new Date().toISOString(),
      }));

      // Update conflict status
      const updatedConflicts = state.conflicts.map((c) =>
        c.id === conflictId ? { ...c, status: 'resolved' as const } : c
      );

      // Mark contending requests as confirmed or waitlisted
      const updatedRequests = state.bookingRequests.map((req) => {
        if (conflict.contendingRequestIds.includes(req.id)) {
          const wasScheduled = conflict.resolution?.feasibleSchedule.some(
            (s) => s.requestId === req.id
          );
          return {
            ...req,
            status: wasScheduled ? ('confirmed' as const) : ('waitlisted' as const),
            facultyComment: comment,
          };
        }
        return req;
      });

      // Notify students
      const newNotif: Notification = {
        id: `notif-${Date.now()}`,
        userId: 'student-1',
        title: 'Allocation Approved by Faculty',
        message: `Your allocation schedule for ${conflict.equipmentName} was approved and committed.`,
        type: 'approval',
        read: false,
        createdAt: new Date().toISOString(),
      };

      set({
        bookings: [...state.bookings, ...newBookings],
        conflicts: updatedConflicts,
        bookingRequests: updatedRequests,
        notifications: [newNotif, ...state.notifications],
      });

      get().addAuditLog(
        'ALLOCATION_APPROVED',
        'conflict_resolution',
        conflictId,
        `Faculty ${state.currentUser.name} approved allocation. ${newBookings.length} bookings committed.`
      );
      return true;
    },

    rejectAllocation: (conflictId, reason) => {
      const state = get();
      if (state.currentRole !== 'faculty') return false;
      const updatedConflicts = state.conflicts.map((c) =>
        c.id === conflictId ? { ...c, status: 'detected' as const } : c
      );
      set({ conflicts: updatedConflicts });
      get().addAuditLog('ALLOCATION_REJECTED', 'conflict_resolution', conflictId, `Rejected: ${reason}`);
      return true;
    },

    modifyAllocation: (conflictId, updatedSchedule, comment) => {
      const state = get();
      if (state.currentRole !== 'faculty') return false;
      const updatedConflicts = state.conflicts.map((c) => {
        if (c.id === conflictId && c.resolution) {
          return {
            ...c,
            resolution: {
              ...c.resolution,
              feasibleSchedule: updatedSchedule,
            },
          };
        }
        return c;
      });
      set({ conflicts: updatedConflicts });
      get().addAuditLog('ALLOCATION_MODIFIED', 'conflict_resolution', conflictId, `Modified schedule slots: ${comment || 'Manual override'}`);
      return true;
    },

    createMaintenanceRecord: (recData) => {
      const state = get();
      if (state.currentRole !== 'lab_manager' && state.currentRole !== 'admin') return false;
      const newRec: MaintenanceRecord = {
        ...recData,
        id: `maint-${Date.now()}`,
      };
      set({ maintenanceRecords: [newRec, ...state.maintenanceRecords] });
      get().addAuditLog('MAINTENANCE_SCHEDULED', 'equipment', recData.equipmentId, `Scheduled maintenance: ${recData.title}`);
      return true;
    },

    updateMaintenanceStatus: (recordId, status) => {
      const state = get();
      if (state.currentRole !== 'lab_manager' && state.currentRole !== 'admin') return false;
      const updated = state.maintenanceRecords.map((m) =>
        m.id === recordId ? { ...m, status } : m
      );
      set({ maintenanceRecords: updated });
      return true;
    },

    markNotificationRead: (id) => {
      set((state) => ({
        notifications: state.notifications.map((n) =>
          n.id === id ? { ...n, read: true } : n
        ),
      }));
    },

    markAllNotificationsRead: () => {
      set((state) => ({
        notifications: state.notifications.map((n) => ({ ...n, read: true })),
      }));
    },

    addAuditLog: (action, entityType, entityId, details) => {
      const state = get();
      const newEntry: AuditLogEntry = {
        id: `audit-${Date.now()}-${Math.floor(Math.random() * 1000)}`,
        timestamp: new Date().toISOString(),
        actorId: state.currentUser.id,
        actorName: state.currentUser.name,
        actorRole: state.currentRole,
        action,
        entityType,
        entityId,
        details,
      };
      set({ auditLogs: [newEntry, ...state.auditLogs] });
    },

    openGuidedTour: () => set({ guidedTourOpen: true, guidedTourStep: 0 }),
    closeGuidedTour: () => set({ guidedTourOpen: false }),
    nextTourStep: () => set((state) => ({ guidedTourStep: state.guidedTourStep + 1 })),
    prevTourStep: () => set((state) => ({ guidedTourStep: Math.max(0, state.guidedTourStep - 1) })),
  };
});
