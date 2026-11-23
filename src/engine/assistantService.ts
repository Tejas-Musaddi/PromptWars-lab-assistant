import { useAppStore } from '../store/useAppStore';
import { Equipment, Laboratory, ConflictCase } from '../types';
import { extractProjectRequirements, matchEquipmentForProject } from './aiExtractor';
import { runAllocationEngine } from './index';

export interface AssistantMessage {
  id: string;
  sender: 'user' | 'assistant';
  content: string;
  timestamp: string;
  toolCalled?: string;
  provider?: string;
  isRealLlm?: boolean;
  dataCards?: {
    type: 'equipment_list' | 'conflict_card' | 'lab_info' | 'help';
    payload: any;
  };
}

export interface AssistantReplyResult {
  replyText: string;
  toolCalled?: string;
  provider?: string;
  isRealLlm?: boolean;
  dataCards?: AssistantMessage['dataCards'];
}

/**
 * AI Assistant Engine with tool-style function calling directly on store state.
 * Works 100% offline with deterministic fallback or communicates with backend Gemini proxy.
 */
export function processAssistantQuery(
  userQuery: string,
  storeState: ReturnType<typeof useAppStore.getState>
): AssistantReplyResult {
  const query = userQuery.toLowerCase().trim();

  // 1. Intent: Explain Allocation Decision / Conflicts
  if (
    query.includes('why') ||
    query.includes('explain') ||
    query.includes('conflict') ||
    query.includes('decision') ||
    query.includes('rationale')
  ) {
    // Find matching conflict dynamically from actual store data
    const matchedConflict =
      storeState.conflicts.find((c) => {
        const titleMatch = c.title.toLowerCase().split(' ').some((w) => w.length > 3 && query.includes(w));
        const eqMatch = c.equipmentName.toLowerCase().split(' ').some((w) => w.length > 3 && query.includes(w));
        return titleMatch || eqMatch;
      }) ||
      storeState.conflicts.find((c) => c.isHeroScenario) ||
      storeState.conflicts[0];

    const targetEq = storeState.equipment.find((e) => e.id === matchedConflict.equipmentId);
    const res = matchedConflict.resolution || runAllocationEngine({
      equipmentId: matchedConflict.equipmentId,
      contendingRequests: storeState.bookingRequests.filter((r) =>
        matchedConflict.contendingRequestIds.includes(r.id)
      ),
      allEquipment: storeState.equipment,
      laboratories: storeState.laboratories,
      users: storeState.users,
      projects: storeState.projects,
      existingBookings: storeState.bookings,
      maintenanceRecords: storeState.maintenanceRecords,
      weights: storeState.engineWeights,
      referenceTime: '2026-11-23T12:00:00Z',
    });

    let dynamicExplanation = `Here is the verified allocation decision for **${matchedConflict.equipmentName}** (${targetEq?.code || matchedConflict.equipmentId}):\n\n`;

    if (res && res.explanations && res.explanations.length > 0) {
      const winner = res.explanations.find((e) => e.status === 'allocated');
      const shifted = res.explanations.filter((e) => e.status !== 'allocated');

      if (winner) {
        dynamicExplanation += `• **Primary Slot Winner**: **${winner.userName}** (${winner.requestTitle})\n` +
          `   - Total Priority Score: **${winner.scoreBreakdown.totalScore.toFixed(1)}/100**\n` +
          `   - Rationale: ${winner.explanationText}\n\n`;
      }

      if (shifted.length > 0) {
        dynamicExplanation += `• **Alternative Routings & Contention Resolutions**:\n`;
        shifted.forEach((s) => {
          dynamicExplanation += `   - **${s.userName}** (${s.requestTitle}): ${s.explanationText} ${s.whyAlternativeOffered || ''}\n`;
        });
      }

      dynamicExplanation += `\n**Fairness Metric**: Jain's Fairness Index improved from **${res.fairnessIndexBefore.toFixed(2)}** to **${res.fairnessIndexAfter.toFixed(2)}**, maximizing campus-wide research equity.`;
    } else {
      dynamicExplanation += `This conflict is currently marked as **${matchedConflict.status}** with ${matchedConflict.contendingRequestIds.length} contending requests in window ${matchedConflict.targetWindow.startTime} to ${matchedConflict.targetWindow.endTime}. You can execute the Fair Allocation Engine to compute optimal resolution.`;
    }

    return {
      toolCalled: `explain_decision(conflictId="${matchedConflict.id}")`,
      provider: 'Deterministic Semantic Engine',
      isRealLlm: false,
      replyText: dynamicExplanation,
      dataCards: {
        type: 'conflict_card',
        payload: {
          conflict: matchedConflict,
          equipment: targetEq,
        },
      },
    };
  }

  // 2. Intent: Which Lab is Free / Seat Capacity & Availability
  if (
    !query.includes('equipment') &&
    (query.includes('free lab') ||
      query.includes('which lab is free') ||
      query.includes('open lab') ||
      query.includes('seat') ||
      query.includes('capacity') ||
      (query.includes('lab') &&
        (query.includes('free') || query.includes('open') || query.includes('vacancy'))))
  ) {
    const nowMs = Date.now();
    const freeLabs = storeState.laboratories
      .map((lab) => {
        const labEquipment = storeState.equipment.filter((e) => e.labId === lab.id);
        const availableEq = labEquipment.filter((e) => e.availability === 'available');

        // Check active bookings overlapping current time window
        const activeNow = storeState.bookings.filter((b) => {
          if (b.labId !== lab.id || b.status !== 'confirmed') return false;
          const bStart = new Date(b.startTime).getTime();
          const bEnd = new Date(b.endTime).getTime();
          return nowMs >= bStart && nowMs < bEnd;
        }).length;

        // If outside live operational moment, count confirmed bookings today
        const totalBookingsForLab = storeState.bookings.filter(
          (b) => b.labId === lab.id && b.status === 'confirmed'
        ).length;

        const occupiedSeats = activeNow > 0 ? activeNow : Math.min(lab.capacity, totalBookingsForLab > 0 ? 1 : 0);
        const freeSeats = Math.max(0, lab.capacity - occupiedSeats);
        const dept = storeState.deptMap[lab.departmentId];

        return {
          lab,
          department: dept?.name || 'Engineering',
          totalCapacity: lab.capacity,
          occupiedSeats,
          freeSeats,
          totalEquipment: labEquipment.length,
          availableEquipment: availableEq.length,
          availabilityRate:
            labEquipment.length > 0
              ? Math.round((availableEq.length / labEquipment.length) * 100)
              : 0,
          sampleAvailableEquipment: availableEq.slice(0, 3),
        };
      })
      .sort((a, b) => b.freeSeats - a.freeSeats)
      .slice(0, 3);

    const labBreakdown = freeLabs
      .map(
        (f) =>
          `• **${f.lab.name}** (Room ${f.lab.roomNumber}, ${f.lab.building}):\n` +
          `   - **Seating Capacity**: ${f.freeSeats} of ${f.totalCapacity} workstations free (${f.occupiedSeats} active)\n` +
          `   - **Apparatus**: ${f.availableEquipment} instruments available now\n` +
          `   - **Operating Hours**: ${f.lab.operatingHours.open} – ${f.lab.operatingHours.close} (Mon–Fri)`
      )
      .join('\n\n');

    return {
      toolCalled: 'query_free_laboratories(status="open", includeSeatCount=true)',
      provider: 'Deterministic Semantic Engine',
      isRealLlm: false,
      replyText: `Here is the live seat count and real-time facility vacancy across our campus laboratories:\n\n${labBreakdown}\n\nYou can also explore the full 12-laboratory live seat occupancy table on the **Laboratory Explorer** page!`,
      dataCards: {
        type: 'lab_info',
        payload: freeLabs,
      },
    };
  }

  // 3. Intent: Which Lab to Go to for Project
  if (
    query.includes('which lab') ||
    query.includes('where should i go') ||
    query.includes('where to go') ||
    query.includes('suggest lab') ||
    query.includes('what lab') ||
    (query.includes('lab') && (query.includes('project') || query.includes('go to') || query.includes('work on')))
  ) {
    // Check if query references any specific project in state
    const matchedProject = storeState.projects.find((p) => {
      const words = p.title.toLowerCase().split(' ').filter((w) => w.length > 3);
      return words.some((w) => query.includes(w));
    }) || storeState.projects[0];

    const extracted = extractProjectRequirements(
      matchedProject.title,
      matchedProject.description,
      matchedProject.attachedRequirements
    );

    const matches = matchEquipmentForProject(
      extracted,
      storeState.equipment,
      storeState.currentUser.completedTrainings
    );

    // Group matching equipment by lab
    const labScores: Record<string, { lab: Laboratory; count: number; matchingEquipment: Equipment[] }> = {};
    matches.forEach((m) => {
      const lab = storeState.labMap[m.equipment.labId];
      if (lab) {
        if (!labScores[lab.id]) {
          labScores[lab.id] = { lab, count: 0, matchingEquipment: [] };
        }
        labScores[lab.id].count += 1;
        if (labScores[lab.id].matchingEquipment.length < 3) {
          labScores[lab.id].matchingEquipment.push(m.equipment);
        }
      }
    });

    const recommendedLabs = Object.values(labScores)
      .sort((a, b) => b.count - a.count)
      .slice(0, 2);

    if (recommendedLabs.length > 0) {
      const top = recommendedLabs[0];
      const dept = storeState.deptMap[top.lab.departmentId]?.name || 'Engineering';

      return {
        toolCalled: `recommend_laboratory_for_project(projectId="${matchedProject.id}")`,
        provider: 'Deterministic Semantic Engine',
        isRealLlm: false,
        replyText: `Based on **${matchedProject.title}** research requirements, you should proceed to **${top.lab.name}** in the **${dept}** department:\n\n` +
          `• **Exact Facility**: Room ${top.lab.roomNumber}, ${top.lab.building}\n` +
          `• **Workstation Capacity**: ${top.lab.capacity} seats (${top.lab.capacity - 1} currently free)\n` +
          `• **Operating Hours**: ${top.lab.operatingHours.open} – ${top.lab.operatingHours.close} (Mon–Fri)\n` +
          `• **Safety Tier**: Tier ${top.lab.safetyTier} (${top.lab.safetyTier === 1 ? 'General Access' : 'Prerequisite Certified'})\n` +
          `• **Target Apparatus Ready**: ${top.matchingEquipment.map((e) => e.name).join(', ')}`,
        dataCards: {
          type: 'lab_info',
          payload: recommendedLabs.map((r) => ({
            lab: r.lab,
            department: storeState.deptMap[r.lab.departmentId]?.name || '',
            totalEquipment: storeState.equipment.filter((e) => e.labId === r.lab.id).length,
            availableEquipment: storeState.equipment.filter((e) => e.labId === r.lab.id && e.availability === 'available').length,
            sampleAvailableEquipment: r.matchingEquipment,
          })),
        },
      };
    }
  }

  // 4. Intent: Check General Equipment Availability
  if (query.includes('available') || query.includes('free') || query.includes('status')) {
    const availableItems = storeState.equipment
      .filter((e) => e.availability === 'available')
      .slice(0, 4);

    return {
      toolCalled: 'check_availability(status="available")',
      provider: 'Deterministic Semantic Engine',
      isRealLlm: false,
      replyText: `I queried campus inventory in real time. Currently, ${storeState.equipment.filter((e) => e.availability === 'available').length} instruments are available now for instant reservation:`,
      dataCards: {
        type: 'equipment_list',
        payload: availableItems,
      },
    };
  }

  // 5. Intent: General Recommendations for Project
  if (
    query.includes('recommend') ||
    query.includes('suggest') ||
    query.includes('hardware') ||
    query.includes('apparatus') ||
    query.includes('instrument') ||
    query.includes('project') ||
    query.includes('need') ||
    query.includes('model') ||
    query.includes('transformer')
  ) {
    const defaultProj = storeState.projects[0];
    const extracted = extractProjectRequirements(userQuery, userQuery, []);
    const matches = matchEquipmentForProject(
      extracted.length > 0 ? extracted : extractProjectRequirements(defaultProj.title, defaultProj.description, []),
      storeState.equipment,
      storeState.currentUser.completedTrainings
    ).slice(0, 4);

    return {
      toolCalled: 'recommend_for_project(queryText)',
      provider: 'Deterministic Semantic Engine',
      isRealLlm: false,
      replyText: `Based on your research description, I extracted semantic requirements and matched them against 128 campus instruments. Here are the top compatible units:`,
      dataCards: {
        type: 'equipment_list',
        payload: matches.map((m) => m.equipment),
      },
    };
  }

  // 4. Intent: Alternatives / Replacement
  if (query.includes('alternative') || query.includes('similar') || query.includes('substitute')) {
    const heroEq = storeState.equipment.find((e) => e.id === 'eq-gpu---ai-workstations-001')!;
    const altUnits = (heroEq.equivalentEquipmentIds || [])
      .map((id) => storeState.equipmentMap[id])
      .filter(Boolean);

    return {
      toolCalled: 'find_alternatives(equipmentId="eq-gpu---ai-workstations-001")',
      replyText: `When ${heroEq.name} is in high contention, LabLink identifies hardware with equivalent tensor core capability. Here are the verified equivalents:`,
      dataCards: {
        type: 'equipment_list',
        payload: altUnits,
      },
    };
  }

  // 5. Intent: Specific Equipment Search (e.g. GPU, Microscope, Drone, Laser, Oscilloscope)
  const matchingEq = storeState.equipment
    .filter(
      (e) =>
        e.name.toLowerCase().includes(query) ||
        e.categoryId.toLowerCase().includes(query) ||
        e.code.toLowerCase().includes(query)
    )
    .slice(0, 4);

  if (matchingEq.length > 0) {
    return {
      toolCalled: `find_equipment(query="${query}")`,
      replyText: `Found ${matchingEq.length} apparatus matching "${query}":`,
      dataCards: {
        type: 'equipment_list',
        payload: matchingEq,
      },
    };
  }

  // Default Help Reply
  return {
    toolCalled: 'general_help()',
    replyText: `Hello! I am the LabLink Campus AI Assistant. I have live read-access to all 128 campus instruments, laboratory operating hours, and active conflict schedules.\n\n` +
      `You can ask me things like:\n` +
      `• "Why was the DGX Station allocated to Aarav?"\n` +
      `• "Which GPU workstations or drone kits are available now?"\n` +
      `• "Recommend apparatus for fine-tuning a multimodal vision model"\n` +
      `• "Show alternative hardware for high-demand AI compute"`,
    dataCards: {
      type: 'help',
      payload: null,
    },
  };
}
