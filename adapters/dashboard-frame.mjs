/**
 * Pure formatting helpers for dashboard bar and activity glyphs.
 *
 * Consumes pre-projected meter data (data contract from the meter module).
 * Does not recalculate usage, infer freshness, or access I/O.
 */

export const MAX_BAR_CELLS = 80;

/* Braille spinner frames — unicode escapes to prevent lookalike corruption.
   U+280B ⠋  U+2819 ⠙  U+2839 ⠹  U+2838 ⠸ */
const UNICODE_SPINNER = ['⠋', '⠙', '⠹', '⠸'];
const ASCII_SPINNER = ['|', '/', '-', '\\'];
const UNICODE_FILLED = '█'; // █
const UNICODE_EMPTY = '░';  // ░
const QUESTION = '?';

/**
 * Format a meter data object into a framed bar, label, and state.
 *
 * @param {object} meter - Pre-projected meter data.
 * @param {'unicode'|'ascii'} style - Rendering style.
 * @returns {{bar: string, label: string, state: string}}
 */
export function meterFrame(meter, style = 'unicode') {
  const invalid = { bar: '[?]', label: 'INVALID', state: 'INVALID' };

  if (!meter || typeof meter !== 'object') {
    return invalid;
  }

  if (style !== 'unicode' && style !== 'ascii') {
    return invalid;
  }

  const { state, cells, filled, empty: empt, percent } = meter;

  if (state === 'UNAVAILABLE' || state === 'NOT_EVALUATED' || state === 'INVALID') {
    const width = isValidWidth(cells) ? cells : 1;
    return {
      bar: '[' + QUESTION.repeat(width) + ']',
      label: state,
      state,
    };
  }

  if (state !== 'FRESH' && state !== 'STALE') {
    const width = isValidWidth(cells) ? cells : 1;
    return {
      bar: '[' + QUESTION.repeat(width) + ']',
      label: 'INVALID',
      state: 'INVALID',
    };
  }

  if (
    !isValidWidth(cells) ||
    !isNonNegInt(filled) ||
    !isNonNegInt(empt) ||
    filled + empt !== cells ||
    typeof percent !== 'number' ||
    !Number.isFinite(percent) ||
    percent < 0
  ) {
    return invalid;
  }

  const fg = style === 'ascii' ? '#' : UNICODE_FILLED;
  const bg = style === 'ascii' ? '-' : UNICODE_EMPTY;
  const bar = '[' + fg.repeat(filled) + bg.repeat(empt) + ']';
  const label = (state === 'STALE' ? 'STALE ' : '') + percent.toFixed(1) + '%';
  return { bar, label, state };
}

/**
 * Return a single activity glyph for the given state and tick.
 *
 * @param {string} state - Activity state name.
 * @param {number} tick - Non-negative safe integer frame index (RUNNING only).
 * @param {'unicode'|'ascii'} style - Rendering style.
 * @param {boolean} reducedMotion - Skip animation frames.
 * @returns {string} One glyph character.
 */
export function activityFrame(state, tick, style = 'unicode', reducedMotion = false) {
  if (style !== 'unicode' && style !== 'ascii') return '?';
  if (typeof reducedMotion !== 'boolean') return '?';

  if (state === 'RUNNING') {
    if (reducedMotion) {
      return style === 'ascii' ? '*' : '●'; // ●
    }
    if (!Number.isSafeInteger(tick) || tick < 0) {
      return '?';
    }
    const frames = style === 'ascii' ? ASCII_SPINNER : UNICODE_SPINNER;
    return frames[tick % 4];
  }

  switch (state) {
    case 'IDLE':
      return style === 'ascii' ? '.' : '·'; // ·
    case 'BLOCKED':
      return '!';
    case 'COMPLETED':
      return style === 'ascii' ? '+' : '✓'; // ✓
    case 'STALE':
      return '~';
    case 'UNAVAILABLE':
    case 'NOT_EVALUATED':
      return '?';
    default:
      return '?';
  }
}

// ---- helpers ----

function isValidWidth(n) {
  return Number.isInteger(n) && n >= 1 && n <= MAX_BAR_CELLS;
}

function isNonNegInt(n) {
  return Number.isInteger(n) && n >= 0;
}
