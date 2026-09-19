import {
  MAX_BAR_CELLS,
  meterFrame,
  activityFrame,
} from '../adapters/dashboard-frame.mjs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

describe('meterFrame', () => {
  it('renders FRESH bar (unicode)', () => {
    const result = meterFrame({ state: 'FRESH', cells: 4, filled: 2, empty: 2, percent: 50 });
    assert.equal(result.bar, '[██░░]');
    assert.equal(result.label, '50.0%');
    assert.equal(result.state, 'FRESH');
  });

  it('renders FRESH bar (ascii)', () => {
    const result = meterFrame(
      { state: 'FRESH', cells: 4, filled: 2, empty: 2, percent: 50 },
      'ascii',
    );
    assert.equal(result.bar, '[##--]');
    assert.equal(result.label, '50.0%');
    assert.equal(result.state, 'FRESH');
  });

  it('renders zero percent', () => {
    const result = meterFrame({ state: 'FRESH', cells: 4, filled: 0, empty: 4, percent: 0 });
    assert.equal(result.bar, '[░░░░]');
    assert.equal(result.label, '0.0%');
    assert.equal(result.state, 'FRESH');
  });

  it('renders UNAVAILABLE', () => {
    const result = meterFrame({ state: 'UNAVAILABLE', cells: 4, percent: 0, filled: 0, empty: 4 });
    assert.equal(result.bar, '[????]');
    assert.equal(result.label, 'UNAVAILABLE');
    assert.equal(result.state, 'UNAVAILABLE');
  });

  it('renders NOT_EVALUATED', () => {
    const result = meterFrame({ state: 'NOT_EVALUATED', cells: 4 });
    assert.equal(result.bar, '[????]');
    assert.equal(result.label, 'NOT_EVALUATED');
    assert.equal(result.state, 'NOT_EVALUATED');
  });

  it('renders STALE with prefix and over-100 percent', () => {
    const result = meterFrame({
      state: 'STALE',
      cells: 4,
      filled: 4,
      empty: 0,
      percent: 125,
    });
    assert.equal(result.bar, '[████]');
    assert.equal(result.label, 'STALE 125.0%');
    assert.equal(result.state, 'STALE');
  });

  it('returns INVALID for non-object input', () => {
    assert.deepEqual(meterFrame(null), { bar: '[?]', label: 'INVALID', state: 'INVALID' });
    assert.deepEqual(meterFrame('hello'), { bar: '[?]', label: 'INVALID', state: 'INVALID' });
    assert.deepEqual(meterFrame(42), { bar: '[?]', label: 'INVALID', state: 'INVALID' });
  });

  it('returns INVALID for unknown style', () => {
    const result = meterFrame(
      { state: 'FRESH', cells: 4, filled: 2, empty: 2, percent: 50 },
      'braille',
    );
    assert.equal(result.state, 'INVALID');
  });

  it('returns INVALID for width exceeding MAX_BAR_CELLS', () => {
    const result = meterFrame({
      state: 'FRESH',
      cells: 81,
      filled: 40,
      empty: 41,
      percent: 50,
    });
    assert.equal(result.state, 'INVALID');
  });

  it('returns INVALID for Number.MAX_SAFE_INTEGER width', () => {
    const result = meterFrame({
      state: 'FRESH',
      cells: Number.MAX_SAFE_INTEGER,
      filled: 0,
      empty: Number.MAX_SAFE_INTEGER,
      percent: 0,
    });
    assert.equal(result.state, 'INVALID');
  });

  it('returns INVALID for zero width', () => {
    const result = meterFrame({
      state: 'FRESH',
      cells: 0,
      filled: 0,
      empty: 0,
      percent: 0,
    });
    assert.equal(result.state, 'INVALID');
  });

  it('returns INVALID for negative width', () => {
    const result = meterFrame({
      state: 'FRESH',
      cells: -1,
      filled: 0,
      empty: 0,
      percent: 0,
    });
    assert.equal(result.state, 'INVALID');
  });

  it('returns INVALID for non-integer width', () => {
    const result = meterFrame({
      state: 'FRESH',
      cells: 4.5,
      filled: 2,
      empty: 2,
      percent: 50,
    });
    assert.equal(result.state, 'INVALID');
  });

  it('returns INVALID for unknown state', () => {
    const result = meterFrame({
      state: 'BOGUS',
      cells: 4,
      filled: 2,
      empty: 2,
      percent: 50,
    });
    assert.equal(result.state, 'INVALID');
    assert.equal(result.label, 'INVALID');
  });

  it('returns INVALID for malformed FRESH display fields', () => {
    assert.equal(
      meterFrame({ state: 'FRESH', cells: 4, filled: '2', empty: 2, percent: 50 }).state,
      'INVALID',
    );
    assert.equal(
      meterFrame({ state: 'FRESH', cells: 4, filled: 2, empty: -1, percent: 50 }).state,
      'INVALID',
    );
    assert.equal(
      meterFrame({ state: 'FRESH', cells: 5, filled: 2, empty: 2, percent: 50 }).state,
      'INVALID',
    );
    assert.equal(
      meterFrame({ state: 'FRESH', cells: 4, filled: 2, empty: 2, percent: '50' }).state,
      'INVALID',
    );
    assert.equal(
      meterFrame({ state: 'FRESH', cells: 4, filled: 2, empty: 2, percent: NaN }).state,
      'INVALID',
    );
  });

  it('preserves frozen input object', () => {
    const input = Object.freeze({
      state: 'FRESH',
      cells: 4,
      filled: 2,
      empty: 2,
      percent: 50,
    });
    const result = meterFrame(input);
    assert.equal(result.state, 'FRESH');
    assert.equal(result.bar, '[██░░]');
  });

  it('returns a new object each call', () => {
    const meter = { state: 'FRESH', cells: 4, filled: 2, empty: 2, percent: 50 };
    const a = meterFrame(meter);
    const b = meterFrame(meter);
    assert.notStrictEqual(a, b);
  });

  it('renders max width (80 cells) without allocating large strings in test', () => {
    const result = meterFrame({
      state: 'FRESH',
      cells: 80,
      filled: 40,
      empty: 40,
      percent: 50,
    });
    assert.equal(result.bar.length, 82); // [ + 80 + ]
    assert.equal(result.state, 'FRESH');
  });

  it('UNAVAILABLE with valid width shows question-mark bar of that width', () => {
    const result = meterFrame({ state: 'UNAVAILABLE', cells: 3 });
    assert.equal(result.bar, '[???]');
  });

  it('INVALID state with valid width shows question-mark bar', () => {
    const result = meterFrame({ state: 'INVALID', cells: 2, filled: 0, empty: 2 });
    assert.equal(result.bar, '[??]');
    assert.equal(result.label, 'INVALID');
  });

  it('unknown state with valid width shows question-mark bar of that width', () => {
    const result = meterFrame({
      state: 'UNKNOWN_STATE',
      cells: 3,
      filled: 1,
      empty: 2,
      percent: 33,
    });
    assert.equal(result.bar, '[???]');
    assert.equal(result.state, 'INVALID');
  });

  it('INVALID style falls back to single question mark when width is also invalid', () => {
    const result = meterFrame(
      { state: 'FRESH', cells: 999, filled: 500, empty: 499, percent: 50 },
      'bad',
    );
    assert.deepEqual(result, { bar: '[?]', label: 'INVALID', state: 'INVALID' });
  });
});

describe('activityFrame', () => {
  /* Independent numeric code-point assertions — not literal copies of the
     implementation. Unicode spinner: U+280B U+2819 U+2839 U+2838.
     ASCII spinner: 0x7C 0x2F 0x2D 0x5C. */
  const unicodePoints = [0x280b, 0x2819, 0x2839, 0x2838];
  const asciiPoints = [0x7c, 0x2f, 0x2d, 0x5c];

  it('cycles all 4 unicode spinner frames and verifies code points', () => {
    for (let i = 0; i < 4; i++) {
      const glyph = activityFrame('RUNNING', i, 'unicode');
      assert.equal(
        glyph.codePointAt(0),
        unicodePoints[i],
        `unicode frame ${i} must be U+${unicodePoints[i].toString(16).toUpperCase()}`,
      );
    }
  });

  it('cycles all 4 ascii spinner frames and verifies code points', () => {
    for (let i = 0; i < 4; i++) {
      const glyph = activityFrame('RUNNING', i, 'ascii');
      assert.equal(
        glyph.codePointAt(0),
        asciiPoints[i],
        `ascii frame ${i} must be U+${asciiPoints[i].toString(16).toUpperCase()}`,
      );
    }
  });

  it('each spinner frame is exactly one code point', () => {
    for (let i = 0; i < 4; i++) {
      assert.equal(
        activityFrame('RUNNING', i, 'unicode').length > 0,
        true,
      );
      assert.equal(
        [...activityFrame('RUNNING', i, 'unicode')].length,
        1,
        `unicode frame ${i} must be one grapheme`,
      );
      assert.equal(
        [...activityFrame('RUNNING', i, 'ascii')].length,
        1,
        `ascii frame ${i} must be one grapheme`,
      );
    }
  });

  it('wraparound: large tick matches small equivalent', () => {
    for (let i = 0; i < 4; i++) {
      assert.equal(
        activityFrame('RUNNING', i, 'unicode'),
        activityFrame('RUNNING', i + 4, 'unicode'),
        `unicode frame ${i} must equal frame ${i + 4}`,
      );
      assert.equal(
        activityFrame('RUNNING', i, 'ascii'),
        activityFrame('RUNNING', i + 4, 'ascii'),
        `ascii frame ${i} must equal frame ${i + 4}`,
      );
    }
  });

  it('literal unicode frames match expected characters', () => {
    assert.equal(activityFrame('RUNNING', 0, 'unicode'), '⠋');
    assert.equal(activityFrame('RUNNING', 1, 'unicode'), '⠙');
    assert.equal(activityFrame('RUNNING', 2, 'unicode'), '⠹');
    assert.equal(activityFrame('RUNNING', 3, 'unicode'), '⠸');
  });

  it('literal ascii frames match expected characters', () => {
    assert.equal(activityFrame('RUNNING', 0, 'ascii'), '|');
    assert.equal(activityFrame('RUNNING', 1, 'ascii'), '/');
    assert.equal(activityFrame('RUNNING', 2, 'ascii'), '-');
    assert.equal(activityFrame('RUNNING', 3, 'ascii'), '\\');
  });

  it('cycles frames at large safe tick indices', () => {
    assert.equal(
      activityFrame('RUNNING', 1000000000, 'unicode'),
      activityFrame('RUNNING', 0, 'unicode'),
    );
  });

  it('returns ? for invalid tick', () => {
    assert.equal(activityFrame('RUNNING', -1, 'unicode'), '?');
    assert.equal(activityFrame('RUNNING', 1.5, 'unicode'), '?');
    assert.equal(activityFrame('RUNNING', '0', 'unicode'), '?');
    assert.equal(activityFrame('RUNNING', null, 'unicode'), '?');
    assert.equal(activityFrame('RUNNING', undefined, 'unicode'), '?');
  });

  it('reduced motion gives fixed glyph', () => {
    assert.equal(activityFrame('RUNNING', 0, 'unicode', true), '●'); // ●
    assert.equal(activityFrame('RUNNING', 0, 'ascii', true), '*');
  });

  it('invalid reducedMotion produces ?', () => {
    assert.equal(activityFrame('RUNNING', 0, 'unicode', 'true'), '?');
    assert.equal(activityFrame('RUNNING', 0, 'unicode', 1), '?');
    assert.equal(activityFrame('RUNNING', 0, 'unicode', null), '?');
  });

  it('IDLE ignores tick', () => {
    assert.equal(activityFrame('IDLE', 0, 'unicode'), '·'); // ·
    assert.equal(activityFrame('IDLE', 999, 'unicode'), '·');
    assert.equal(activityFrame('IDLE', 0, 'ascii'), '.');
  });

  it('BLOCKED returns !', () => {
    assert.equal(activityFrame('BLOCKED', 0, 'unicode'), '!');
    assert.equal(activityFrame('BLOCKED', 0, 'ascii'), '!');
  });

  it('COMPLETED returns check glyph', () => {
    assert.equal(activityFrame('COMPLETED', 0, 'unicode'), '✓'); // ✓
    assert.equal(activityFrame('COMPLETED', 0, 'ascii'), '+');
  });

  it('STALE returns ~', () => {
    assert.equal(activityFrame('STALE', 0, 'unicode'), '~');
    assert.equal(activityFrame('STALE', 0, 'ascii'), '~');
  });

  it('UNAVAILABLE and NOT_EVALUATED return ?', () => {
    assert.equal(activityFrame('UNAVAILABLE', 0, 'unicode'), '?');
    assert.equal(activityFrame('NOT_EVALUATED', 0, 'unicode'), '?');
  });

  it('unknown state returns ?', () => {
    assert.equal(activityFrame('BOGUS', 0, 'unicode'), '?');
  });

  it('invalid style returns ?', () => {
    assert.equal(activityFrame('IDLE', 0, 'braille'), '?');
  });

  it('non-running states ignore tick value', () => {
    assert.equal(activityFrame('IDLE', -999, 'unicode'), '·');
    assert.equal(activityFrame('COMPLETED', 'abc', 'unicode'), '✓');
  });
});

describe('constants', () => {
  it('MAX_BAR_CELLS is 80', () => {
    assert.equal(MAX_BAR_CELLS, 80);
  });
});
