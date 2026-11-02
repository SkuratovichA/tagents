// The scaffold section of the plugin vectors: the five files node's `scaffoldFiles` builds for each `(name, dir, core)` triple of `packages/core/test/fixtures/scaffold/triples.ts`. The Rust renderer of `plugin new` has to produce the same bytes from the same template.
import { scaffoldFiles } from '../../packages/core/src/cli/scaffold.ts';
import { SCAFFOLD_TRIPLES } from '../../packages/core/test/fixtures/scaffold/triples.ts';

export function scaffoldVectors(): unknown {
  return {
    cases: SCAFFOLD_TRIPLES.map(({ label, name, dir, core }) => ({ label, name, dir, core, files: scaffoldFiles(name, dir, core) })),
  };
}
