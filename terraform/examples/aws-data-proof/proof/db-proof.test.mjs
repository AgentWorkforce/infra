import { test } from 'node:test';
import assert from 'node:assert/strict';
import { refused } from './db-proof.mjs';

test('refusals require the exact authorization/TLS class, not a network failure or success', async () => {
  await refused(async () => { throw Object.assign(new Error('synthetic'), { code: '42501' }); }, ['42501']);
  await assert.rejects(refused(async () => {}, ['42501']));
  await assert.rejects(refused(async () => { throw Object.assign(new Error('synthetic'), { code: 'ECONNREFUSED' }); }, ['42501']));
});
