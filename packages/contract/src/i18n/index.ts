// A typed t() built on the interpolation @tagents/knowledge already ships — not on i18next, whose key typing comes from a global `declare module` that cannot be augmented a second time (see packages/knowledge/src/i18n/index.ts and LEARNING.md). English only, because what it renders is read by Claude in the repo and must not depend on the machine that generated it. Imported from the source file, not the package name: the package name is a built dist, and importing its index would load the SQLite and MCP modules just to interpolate a string.
import { interpolate, type Vars } from '../../../knowledge/src/i18n/index.ts';
import { en } from './en.ts';

export type ContractKey = keyof typeof en;
/** Same call shape as i18next's `t`: a key, and the values its {{slots}} take. */
export type Translate = (key: ContractKey, vars?: Vars) => string;

/** A fresh English translator per call: the contract and the references are English by design, whatever TAGENTS_LOCALE says. */
export function createT(): Translate {
  return (key, vars) => interpolate(en[key], vars ?? {});
}
