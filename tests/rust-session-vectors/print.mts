// The print section of the session vectors: what `JSON.stringify` writes for a document `JSON.parse` read, compact and in the two-space layout of `json()` in `cli/exit.ts`.
//
// A case is the text of a document, and the answers are texts too. The documents hold the lone surrogates as the six characters of the escape, which stay in the file as plain text; a string in this file that held the surrogate itself could not be read back by `serde_json`, and `main` refuses to write one.
import { json } from '../../packages/core/src/cli/exit.ts';

/** Documents whose numbers print the way `Number::toString` writes them. */
const NUMBERS = [
  '1e21',
  '1e20',
  '-0',
  '0',
  '12345678901234567890',
  '123456789012345678901234',
  '1e999',
  '-1e999',
  '0.1',
  '1E5',
  '5e-7',
  '0.000001',
  '1e-7',
  '1.5e300',
  '100',
  '4.35',
  '4294967296',
  '0.30000000000000004',
  '9007199254740993',
  '2.5e-324',
  '1.7976931348623157e308',
  '270348394056782.125',
  '[1,-0,1e21,0.5]',
];

/** Strings, as the document that holds them. */
const STRINGS = [
  '""',
  '"plain"',
  '"quote \\" backslash \\\\ slash \\/"',
  '"\\b\\f\\n\\r\\t"',
  '"\\u0000\\u0001\\u001f\\u007f"',
  '"\\u2028\\u2029"',
  '"café 中 \u{1F600}"',
  '"\\ud83d\\ude00"',
  '"\\ud83d"',
  '"\\ude00"',
  '"\\ud83dx"',
  '"\\ude00\\ud83d"',
  '"a\\ud83d"',
  '"\\ud83d\\ud83d\\ude00"',
  '["\\ud83d","\\ude00"]',
  '"\\u00e9\\u00E9"',
  '"\\uFEFF"',
];

/** Objects, for the order of their keys and for what a key may be. */
const KEYS = [
  '{}',
  '[]',
  '{"a":1,"b":2,"a":3}',
  '{"b":1,"2":2,"1":3,"a":4,"10":5,"01":6}',
  '{"4294967294":1,"4294967295":2,"a":3,"0":4}',
  '{"9007199254740991":1,"b":2,"1":3}',
  '{"-1":1,"1.5":2,"1e2":3,"+1":4,"1":5}',
  '{"__proto__":1,"a":2}',
  '{"a":1,"__proto__":{"x":1},"b":2}',
  '{"constructor":1,"toString":2,"hasOwnProperty":3}',
  '{"":1,"a":2}',
  '{"\\u00e9":1,"e":2,"\\ud83d\\ude00":3}',
  '{"a\\"b":1,"a\\\\b":2,"a\\nb":3}',
  '{"x":{"b":1,"1":2},"0":{"z":[1,{"y":2,"3":4}]}}',
  '{"a":[],"b":{},"c":[[]],"d":[{}]}',
  '{"a":null,"b":true,"c":false}',
  '[[1,[2,[3,[]]]],{"a":{"b":{"c":{}}}}]',
  ' \n\t{ "a" : [ 1 , 2 ] }\r\n',
];

/** Texts `JSON.parse` refuses: the answer is a null, and Rust must refuse them too. */
const REFUSED = ['', ' ', '{', '[1,]', '{"a":1,}', "{'a':1}", '{a:1}', '01', '1.', '.5', '+1', '-', '1e', 'NaN', 'Infinity', 'undefined', 'tru', '"a', '"\t"', '"\\x41"', '"\\u12"', '{"a":1}x', '[1] [2]', '﻿{}'];

interface PrintCase {
  readonly document: string;
  /** `JSON.stringify(JSON.parse(document))`, or null when the parse throws. */
  readonly compact: string | null;
  /** `json(JSON.parse(document))`, the text `session open` writes, newline included. */
  readonly pretty: string | null;
}

function run(document: string): PrintCase {
  try {
    const value: unknown = JSON.parse(document);
    return { document, compact: JSON.stringify(value), pretty: json(value) };
  } catch {
    return { document, compact: null, pretty: null };
  }
}

export function printVectors(): unknown {
  return { cases: [...NUMBERS, ...STRINGS, ...KEYS, ...REFUSED].map(run) };
}
