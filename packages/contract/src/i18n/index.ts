// A typed t() with its own interpolation, not i18next, whose key typing comes from a global `declare module` that cannot be augmented a second time. English only, because what it renders is read by Claude in the repo and must not depend on the machine that generated it.
import { en } from './en.ts';

export type Vars = Readonly<Record<string, string | number>>;

const SLOT = /\{\{(\w+)\}\}/g;

/** Fills the {{slots}} of a template; a slot with no value stays as written. */
export function interpolate(template: string, vars: Vars): string {
  return template.replace(SLOT, (whole, name: string) => {
    const value = vars[name];
    return value === undefined ? whole : String(value);
  });
}

export type ContractKey = keyof typeof en;
/** Same call shape as i18next's `t`: a key, and the values its {{slots}} take. */
export type Translate = (key: ContractKey, vars?: Vars) => string;

/** A fresh English translator per call: the contract and the references are English by design, whatever TAGENTS_LOCALE says. */
export function createT(): Translate {
  return (key, vars) => interpolate(en[key], vars ?? {});
}
