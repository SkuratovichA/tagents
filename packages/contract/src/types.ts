// The shapes the generator's stages hand to each other. Type-only, so the stages that are pure never load the heavy modules that produce them.
import type { CliContract } from '../../core/src/cli/spec.ts';
import type { ApiReport } from './api.ts';
import type { JsonObject } from './json.ts';

export type { ApiReport, CliContract };

export interface McpTool {
  readonly name: string;
  readonly description: string;
  readonly inputSchema: JsonObject;
  readonly outputSchema?: JsonObject;
  /** the hints a client asks permission by (read-only, destructive, open-world), when the server states any */
  readonly annotations?: JsonObject;
}

export interface McpServerSpec {
  readonly name: string;
  readonly tools: readonly McpTool[];
}

export interface Script {
  readonly name: string;
  /** what `<name> --help` prints, byte for byte */
  readonly help: string;
}

/** Everything the plugin's contract is read from: the code, not the disk. */
export interface Sources {
  readonly cli: readonly CliContract[];
  readonly mcp: readonly McpServerSpec[];
  readonly api: readonly ApiReport[];
  readonly scripts: readonly Script[];
}
