/**
 * Computes Jain's Fairness Index:
 * J(x1, x2, ..., xn) = (sum(xi))^2 / (n * sum(xi^2))
 * Returns a value between 0.0 and 1.0.
 */
export function calculateJainsFairnessIndex(values: number[]): number {
  if (!values || values.length === 0) return 1.0;
  if (values.length === 1) return 1.0;

  const sum = values.reduce((acc, curr) => acc + Math.max(0, curr), 0);
  if (sum === 0) return 1.0; // Equal distribution across population with zero prior allocations

  const sumSq = values.reduce((acc, curr) => acc + Math.max(0, curr) * Math.max(0, curr), 0);
  const n = values.length;
  if (sumSq === 0) return 1.0;

  const index = (sum * sum) / (n * sumSq);
  return Math.min(1.0, Math.max(0.0, Math.round(index * 100) / 100));
}

/**
 * Computes Fairness Index on student usage hours before and after a set of proposed allocations.
 */
export function computeFairnessComparison(
  studentPriorHours: number[],
  addedHoursPerStudent: number[]
): {
  fairnessBefore: number;
  fairnessAfter: number;
} {
  // To evaluate fairness of access, lower prior hours should ideally receive more hours.
  // We measure equity across (priorHours + addedHours)
  const combined = studentPriorHours.map((prior, i) => prior + (addedHoursPerStudent[i] || 0));

  const fairnessBefore = calculateJainsFairnessIndex(studentPriorHours);
  const fairnessAfter = calculateJainsFairnessIndex(combined);

  return {
    fairnessBefore,
    fairnessAfter,
  };
}
