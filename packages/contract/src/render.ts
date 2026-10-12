// The markdown references. Every heading and label goes through t(), and the caller hands in the English translator: the references are read by Claude, in the repo, and must not depend on the machine they were generated on.
//
// One sentence or paragraph is one physical line.
import type { Translate } from './i18n/index.ts';
import { isJsonArray, isJsonObject, type JsonObject, type JsonValue } from './json.ts';
import type { CliContract, McpServerSpec, McpTool, Script } from './types.ts';

type CliCommand = CliContract['commands'][number];

const cell = (text: string): string => text.replace(/\|/g, '\\|').replace(/\s*\n\s*/g, ' ');

function table(header: readonly string[], rows: readonly (readonly string[])[]): string[] {
  return [
    `| ${header.join(' | ')} |`,
    `|${header.map(() => '---').join('|')}|`,
    ...rows.map((row) => `| ${row.map(cell).join(' | ')} |`),
  ];
}

/** A fence longer than any backtick run inside the body, so the body can never close it early. */
function fenced(language: string, body: string): string[] {
  const longest = Math.max(0, ...[...body.matchAll(/`+/g)].map((m) => m[0].length));
  const fence = '`'.repeat(Math.max(3, longest + 1));
  return [`${fence}${language}`, body.endsWith('\n') ? body.slice(0, -1) : body, fence];
}

/** Blocks of lines, one blank line between blocks, one trailing newline. */
function document(blocks: readonly (readonly string[])[]): string {
  return `${blocks.map((b) => b.join('\n')).join('\n\n')}\n`;
}

export function usageLine(program: string, command: CliCommand): string {
  const flags = Object.entries(command.options).map(([name, spec]) => {
    const value = spec.type === 'string' ? ` <${name}>${spec.multiple === true ? '…' : ''}` : '';
    const flag = `--${name}${value}`;
    return command.required.includes(name) ? flag : `[${flag}]`;
  });
  return [program, ...command.path, ...command.positionals, ...flags].join(' ');
}

function renderVerb(program: string, command: CliCommand, t: Translate): string[][] {
  const flags = Object.entries(command.options);
  return [
    [`### ${command.path.join(' ')}`],
    [command.summary],
    [`${t('usageLabel')}: \`${usageLine(program, command)}\``],
    flags.length === 0
      ? [t('noFlags')]
      : table(
          [t('colFlag'), t('colType'), t('colRequired'), t('colRepeatable')],
          flags.map(([name, spec]) => [
            `\`--${name}\``,
            spec.type,
            command.required.includes(name) ? t('yes') : t('no'),
            spec.multiple === true ? t('yes') : t('no'),
          ])
        ),
  ];
}

export function renderCli(contracts: readonly CliContract[], t: Translate): string {
  return document([
    [`# ${t('cliTitle')}`],
    [t('generatedNote')],
    ...contracts.flatMap((c) => [
      [`## ${c.program}`],
      [`### ${t('exitCodes')}`],
      table(
        [t('colCode'), t('colOutcome')],
        Object.entries(c.exit).map(([outcome, code]) => [String(code), outcome])
      ),
      ...c.commands.flatMap((command) => renderVerb(c.program, command, t)),
    ]),
  ]);
}

/** A JSON Schema's type as a reader wants it: `string`, `integer[]`, `"a" | "b"`, `string | null`. */
export function schemaType(schema: JsonValue | undefined, t: Translate): string {
  if (!isJsonObject(schema)) return t('typeUnspecified');
  const choices = schema['enum'];
  if (isJsonArray(choices)) return choices.map((c) => JSON.stringify(c)).join(' | ');
  const type = schema['type'];
  if (type === 'array') {
    const items = schema['items'];
    return items === undefined ? 'array' : `${schemaType(items, t)}[]`;
  }
  if (typeof type === 'string') return type;
  if (isJsonArray(type)) return type.map(String).join(' | ');
  for (const key of ['anyOf', 'oneOf']) {
    const alternatives = schema[key];
    if (isJsonArray(alternatives)) return alternatives.map((a) => schemaType(a, t)).join(' | ');
  }
  return t('typeUnspecified');
}

function inputRows(schema: JsonObject, t: Translate): string[][] {
  const properties = schema['properties'];
  if (!isJsonObject(properties)) return [];
  const required = schema['required'];
  return Object.entries(properties).map(([name, property]) => {
    const description = isJsonObject(property) ? property['description'] : undefined;
    return [
      `\`${name}\``,
      schemaType(property, t),
      isJsonArray(required) && required.includes(name) ? t('yes') : t('no'),
      typeof description === 'string' ? description : '',
    ];
  });
}

function renderTool(tool: McpTool, t: Translate): string[][] {
  const rows = inputRows(tool.inputSchema, t);
  return [
    [`### ${tool.name}`],
    [tool.description],
    [`#### ${t('inputs')}`],
    rows.length === 0
      ? [t('noInputs')]
      : table([t('colInput'), t('colType'), t('colRequired'), t('colDescription')], rows),
    [`#### ${t('inputSchema')}`],
    fenced('json', JSON.stringify(tool.inputSchema, null, 2)),
    ...(tool.outputSchema === undefined
      ? []
      : [[`#### ${t('outputSchema')}`], fenced('json', JSON.stringify(tool.outputSchema, null, 2))]),
  ];
}

export function renderMcp(servers: readonly McpServerSpec[], t: Translate): string {
  return document([
    [`# ${t('mcpTitle')}`],
    [t('generatedNote')],
    ...servers.flatMap((server) => [
      [`## ${server.name}`],
      ...server.tools.flatMap((tool) => renderTool(tool, t)),
    ]),
  ]);
}

export function renderScripts(scripts: readonly Script[], t: Translate): string {
  return document([
    [`# ${t('scriptsTitle')}`],
    [t('generatedNote')],
    ...scripts.flatMap((script) => [
      [`## ${script.name}`],
      [t('scriptHelp', { script: script.name })],
      fenced('text', script.help),
    ]),
  ]);
}
