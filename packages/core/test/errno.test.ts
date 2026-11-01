// What `errnoCode` reads from a thrown value: the string `code` of an Error, and nothing from anything else.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { errnoCode } from '../src/errno.ts';
import { tmpDir } from '../src/testkit.ts';

test('errnoCode: the code of an error a syscall threw', () => {
  const missing = path.join(tmpDir('errno'), 'missing');
  assert.throws(
    () => fs.readFileSync(missing),
    (e: unknown) => errnoCode(e) === 'ENOENT'
  );
});

test('errnoCode: the string code of any Error', () => {
  assert.equal(errnoCode(Object.assign(new Error('busy'), { code: 'EBUSY' })), 'EBUSY');
});

test('errnoCode: undefined for an Error without a code, a code that is not a string, and a value that is not an Error', () => {
  assert.equal(errnoCode(new Error('plain')), undefined);
  assert.equal(errnoCode(Object.assign(new Error('numeric'), { code: 2 })), undefined);
  assert.equal(errnoCode({ code: 'ENOENT' }), undefined);
  assert.equal(errnoCode('ENOENT'), undefined);
  assert.equal(errnoCode(undefined), undefined);
});
