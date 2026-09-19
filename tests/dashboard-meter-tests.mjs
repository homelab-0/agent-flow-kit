import { strictEqual, deepStrictEqual, throws, ok } from 'node:assert/strict';
import { describe, it } from 'node:test';
import { projectMeter } from '../adapters/dashboard-meter.mjs';

const invalidShape = {
  state: 'INVALID',
  used: null,
  limit: null,
  percent: null,
  remaining: null,
  filled: null,
  empty: null,
  overLimit: null,
};

describe('projectMeter', () => {
  /* AC1: Known zero is valid; unavailable is nonnumeric */
  describe('AC1: known zero vs unavailable', () => {
    it('known zero returns zero filled cells', () => {
      const r = projectMeter({ state: 'FRESH', used: 0, limit: 100 }, 10);
      strictEqual(r.filled, 0);
      strictEqual(r.percent, 0);
      strictEqual(r.remaining, 100);
      strictEqual(r.overLimit, false);
    });

    it('UNAVAILABLE discards numerics and returns nulls', () => {
      const r = projectMeter({ state: 'UNAVAILABLE', used: 5, limit: 10 }, 10);
      strictEqual(r.state, 'UNAVAILABLE');
      strictEqual(r.used, null);
      strictEqual(r.limit, null);
      strictEqual(r.percent, null);
      strictEqual(r.remaining, null);
      strictEqual(r.filled, null);
      strictEqual(r.empty, null);
      strictEqual(r.overLimit, null);
      strictEqual(r.cells, 10);
    });

    it('NOT_EVALUATED discards numerics and returns full null shape', () => {
      const r = projectMeter({ state: 'NOT_EVALUATED', used: 0, limit: 1 }, 5);
      strictEqual(r.state, 'NOT_EVALUATED');
      strictEqual(r.used, null);
      strictEqual(r.limit, null);
      strictEqual(r.percent, null);
      strictEqual(r.remaining, null);
      strictEqual(r.filled, null);
      strictEqual(r.empty, null);
      strictEqual(r.overLimit, null);
      strictEqual(r.cells, 5);
    });
  });

  /* AC2: partial, fractional, full — correct segments, unrounded percent */
  describe('AC2: partial / fractional / full values', () => {
    it('partial fill produces correct segment counts', () => {
      const r = projectMeter({ state: 'FRESH', used: 40, limit: 100 }, 10);
      strictEqual(r.filled, 4);
      strictEqual(r.empty, 6);
      strictEqual(r.filled + r.empty, 10);
      strictEqual(r.percent, 40);
    });

    it('fractional values floor-fill cells and retain unrounded percent', () => {
      const r = projectMeter({ state: 'FRESH', used: 33.33, limit: 100 }, 10);
      strictEqual(r.filled, 3);
      strictEqual(r.empty, 7);
      strictEqual(r.percent, 33.33);
    });

    it('exact full fills all cells', () => {
      const r = projectMeter({ state: 'FRESH', used: 100, limit: 100 }, 8);
      strictEqual(r.filled, 8);
      strictEqual(r.empty, 0);
      strictEqual(r.percent, 100);
      strictEqual(r.remaining, 0);
    });
  });

  /* AC3: overshoot — numeric truth, bounded visual */
  describe('AC3: overshoot', () => {
    it('reports overLimit with percentage above 100, filled capped at cells', () => {
      const r = projectMeter({ state: 'FRESH', used: 150, limit: 100 }, 10);
      strictEqual(r.overLimit, true);
      strictEqual(r.percent, 150);
      strictEqual(r.filled, 10);
      strictEqual(r.empty, 0);
      strictEqual(r.remaining, 0);
    });
  });

  /* AC4: stale preserves state and numbers */
  describe('AC4: stale observations', () => {
    it('preserves STALE state with correct numbers', () => {
      const r = projectMeter({ state: 'STALE', used: 50, limit: 200 }, 10);
      strictEqual(r.state, 'STALE');
      strictEqual(r.filled, 2);
      strictEqual(r.percent, 25);
      strictEqual(r.remaining, 150);
    });
  });

  /* AC5: missing-data states discard attached numerics */
  describe('AC5: missing-data discard', () => {
    it('UNAVAILABLE with large numbers still nulls everything', () => {
      const r = projectMeter({ state: 'UNAVAILABLE', used: 999, limit: 1 }, 4);
      strictEqual(r.used, null);
      strictEqual(r.limit, null);
      strictEqual(r.percent, null);
      strictEqual(r.filled, null);
      strictEqual(r.cells, 4);
    });
  });

  /* AC6: invalid / malformed observations fail explicitly (no throw) */
  describe('AC6: invalid observations return INVALID shape', () => {
    it('null observation yields full INVALID shape', () => {
      const r = projectMeter(null, 5);
      deepStrictEqual(r, { ...invalidShape, cells: 5 });
    });

    it('undefined observation yields full INVALID shape', () => {
      const r = projectMeter(undefined, 5);
      deepStrictEqual(r, { ...invalidShape, cells: 5 });
    });

    it('unknown state yields INVALID', () => {
      const r = projectMeter({ state: 'GUESS', used: 1, limit: 2 }, 5);
      strictEqual(r.state, 'INVALID');
      strictEqual(r.used, null);
      strictEqual(r.percent, null);
    });

    it('negative usage yields INVALID', () => {
      const r = projectMeter({ state: 'FRESH', used: -1, limit: 10 }, 5);
      strictEqual(r.state, 'INVALID');
    });

    it('zero limit yields INVALID', () => {
      const r = projectMeter({ state: 'FRESH', used: 0, limit: 0 }, 5);
      strictEqual(r.state, 'INVALID');
    });

    it('non-finite used yields INVALID', () => {
      const r = projectMeter({ state: 'FRESH', used: Infinity, limit: 10 }, 5);
      strictEqual(r.state, 'INVALID');
    });

    it('string numerics yield INVALID', () => {
      const r = projectMeter({ state: 'FRESH', used: '10', limit: 100 }, 5);
      strictEqual(r.state, 'INVALID');
    });

    it('finite inputs with non-finite derived percent (multiply overflow) yield INVALID', () => {
      ok(Number.isFinite(Number.MAX_VALUE), 'MAX_VALUE is finite');
      const r = projectMeter({ state: 'FRESH', used: Number.MAX_VALUE, limit: 1 }, 10);
      strictEqual(r.state, 'INVALID');
      deepStrictEqual(r, { ...invalidShape, cells: 10 });
    });

    it('finite inputs with non-finite derived percent (division overflow) yield INVALID', () => {
      ok(Number.isFinite(Number.MIN_VALUE) && Number.MIN_VALUE > 0, 'MIN_VALUE is finite positive');
      const r = projectMeter({ state: 'STALE', used: 1, limit: Number.MIN_VALUE }, 10);
      strictEqual(r.state, 'INVALID');
      deepStrictEqual(r, { ...invalidShape, cells: 10 });
    });
  });

  /* AC7: invalid cells throw RangeError regardless of observation */
  describe('AC7: invalid cells throw RangeError', () => {
    const bad = [{ state: 'FRESH', used: 0, limit: 10 }, { state: 'UNAVAILABLE' }];
    const invalidCells = [undefined, 0, -1, 1.5, Infinity, NaN, '10', Number.MAX_SAFE_INTEGER + 2];

    for (const obs of bad) {
      for (const c of invalidCells) {
        it(`cells=${String(c)} throws RangeError for ${obs.state}`, () => {
          throws(() => projectMeter(obs, c), RangeError);
        });
      }
    }
  });

  /* AC8: frozen input, deterministic distinct objects, independence */
  describe('AC8: immutability and determinism', () => {
    it('frozen observation is not mutated', () => {
      const obs = Object.freeze({ state: 'FRESH', used: 50, limit: 100 });
      projectMeter(obs, 10);
      ok(Object.isFrozen(obs));
    });

    it('repeated calls return distinct objects with equal content', () => {
      const obs = { state: 'FRESH', used: 50, limit: 100 };
      const a = projectMeter(obs, 10);
      const b = projectMeter(obs, 10);
      ok(a !== b, 'should be different objects');
      deepStrictEqual(a, b, 'should have equal content');
    });

    it('independent observations do not exchange state', () => {
      const a = projectMeter({ state: 'FRESH', used: 0, limit: 10 }, 5);
      const b = projectMeter({ state: 'STALE', used: 1, limit: 2 }, 5);
      strictEqual(a.state, 'FRESH');
      strictEqual(b.state, 'STALE');
    });
  });
});
