// The decode section of the session vectors: what node's UTF-8 decoding makes of bytes that are not all valid, which is how a transcript is read and how a line of the child's output is read once the decoder fix has cut it from the bytes.
import { StringDecoder } from 'node:string_decoder';

const SAMPLES: ReadonlyArray<readonly [string, string]> = [
  ['ascii', '61 62 63'],
  ['two-byte', 'd1 8f'],
  ['emoji', 'f0 9f 98 80'],
  ['bom', 'ef bb bf 61'],
  ['lone-continuation', '61 80 62'],
  ['truncated-two-byte', '61 d1'],
  ['truncated-three-byte', 'e2 82'],
  ['truncated-four-byte', 'f0 9f 98'],
  ['truncated-then-ascii', 'f0 9f 61'],
  ['overlong-slash', 'c0 af'],
  ['overlong-three', 'e0 80 af'],
  ['surrogate-high', 'ed a0 80'],
  ['surrogate-low', 'ed bf bf'],
  ['above-max', 'f4 90 80 80'],
  ['f5', 'f5 80 80 80'],
  ['ff', 'ff'],
  ['fe-ff', 'fe ff 61'],
  ['many-bad', '80 80 80 80'],
  ['pair-of-bad-then-good', 'c3 28 c3 a9'],
  ['nul-between', '61 00 62'],
  ['newline-after-bad', 'e2 82 0a 61'],
];

export function decodeVectors(): unknown {
  return {
    cases: SAMPLES.map(([name, hex]) => {
      const bytes = Buffer.from(hex.replaceAll(' ', ''), 'hex');
      const text = bytes.toString('utf8');
      // One StringDecoder over the whole sequence agrees with `toString`, which the fix of the driver relies on.
      const decoder = new StringDecoder('utf8');
      const streamed = decoder.write(bytes) + decoder.end();
      if (streamed !== text) throw new Error(`StringDecoder and toString disagree on ${name}`);
      return { name, hex: hex.replaceAll(' ', ''), json: JSON.stringify(text) };
    }),
  };
}
