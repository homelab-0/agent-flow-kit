const VALID_STATES = new Set(['FRESH', 'STALE', 'UNAVAILABLE', 'NOT_EVALUATED']);
const NUMERIC_STATES = new Set(['FRESH', 'STALE']);

/**
 * Validate that `cells` is a positive safe integer. Throw RangeError otherwise.
 */
function validateCells(cells) {
  if (typeof cells !== 'number' || !Number.isFinite(cells)) throw new RangeError('cells must be a finite number');
  if (!Number.isInteger(cells)) throw new RangeError('cells must be an integer');
  if (cells <= 0) throw new RangeError('cells must be positive');
  if (cells > Number.MAX_SAFE_INTEGER) throw new RangeError('cells exceeds safe integer');
}

/**
 * Build the null-valued result shape for non-numeric observations.
 */
function nullResult(state, cells) {
  return {
    state,
    used: null,
    limit: null,
    percent: null,
    remaining: null,
    cells,
    filled: null,
    empty: null,
    overLimit: null,
  };
}

/**
 * Validate observation values for numeric states (FRESH / STALE).
 * Returns true when all values are acceptable.
 */
function isValidNumeric(obs) {
  if (typeof obs.used !== 'number' || !Number.isFinite(obs.used) || obs.used < 0) return false;
  if (typeof obs.limit !== 'number' || !Number.isFinite(obs.limit) || obs.limit <= 0) return false;
  const percent = (obs.used / obs.limit) * 100;
  if (!Number.isFinite(percent)) return false;
  return true;
}

/**
 * Project a numeric observation onto a fixed cell grid.
 *
 * @param {object} observation - { state, used, limit }
 * @param {number} cells - positive safe integer count of visual segments
 * @returns {object} projection result
 */
export function projectMeter(observation, cells) {
  validateCells(cells);

  if (!observation || typeof observation !== 'object') {
    return nullResult('INVALID', cells);
  }

  const { state, used, limit } = observation;

  if (!NUMERIC_STATES.has(state)) {
    if (VALID_STATES.has(state)) {
      return nullResult(state, cells);
    }
    return nullResult('INVALID', cells);
  }

  if (!isValidNumeric(observation)) {
    return nullResult('INVALID', cells);
  }

  const percent = (used / limit) * 100;
  const remaining = Math.max(0, limit - used);
  const overLimit = used > limit;
  const filled = Math.floor(Math.min(1, used / limit) * cells);
  const empty = cells - filled;

  return {
    state,
    used,
    limit,
    percent,
    remaining,
    cells,
    filled,
    empty,
    overLimit,
  };
}
