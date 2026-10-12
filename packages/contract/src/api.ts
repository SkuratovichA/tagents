// The public TypeScript API of each package, as API Extractor reports it.

import { readdir, readFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Extractor, ExtractorConfig, ExtractorLogLevel } from '@microsoft/api-extractor';
import type { ExtractorMessage } from '@microsoft/api-extractor';
import ts from 'typescript';
import { isJsonObject, toJson } from './json.ts';
import { isMissing } from './missing.ts';
import { byCodeUnit } from './order.ts';

export interface ApiReport {
  /** the package name from its package.json, e.g. '@tagents/core' */
  readonly package: string;
  /** the basename of the reference file the report becomes, e.g. 'core.api.md' */
  readonly file: string;
  /** the report itself, markdown with LF newlines */
  readonly markdown: string;
}

interface PublicPackage {
  readonly name: string;
  readonly dir: string;
}

// Not under `node_modules`: API Extractor treats every declaration file below one as an external package and would report its exports as bare imports. From here `@tagents/core` still resolves through this package's own `node_modules`. Each `apiReports` call makes its own directory in here, so runs in parallel processes never delete one another's files.
const CACHE = fileURLToPath(new URL('../.cache/', import.meta.url));

async function publicPackages(root: string): Promise<readonly PublicPackage[]> {
  const found: PublicPackage[] = [];
  for (const entry of await readdir(join(root, 'packages'), { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const dir = join(root, 'packages', entry.name);
    let manifest: unknown;
    try {
      manifest = JSON.parse(await readFile(join(dir, 'package.json'), 'utf8'));
    } catch (error) {
      if (isMissing(error)) continue;
      throw error;
    }
    if (typeof manifest !== 'object' || manifest === null) continue;
    const { name, private: isPrivate, exports } = manifest as Record<string, unknown>;
    if (typeof name !== 'string' || isPrivate === true || exports === undefined) continue;
    found.push({ name, dir });
  }
  return found.sort((a, b) => byCodeUnit(a.name, b.name));
}

/** Declarations only, from the package's tsconfig.build.json, into `outDir` — never into `dist`. */
function emitDeclarations(dir: string, outDir: string): void {
  const configPath = join(dir, 'tsconfig.build.json');
  const read = ts.readConfigFile(configPath, ts.sys.readFile);
  if (read.error) throw new Error(ts.flattenDiagnosticMessageText(read.error.messageText, '\n'));
  const parsed = ts.parseJsonConfigFileContent(read.config, ts.sys, dir, undefined, configPath);
  const program = ts.createProgram({
    rootNames: parsed.fileNames,
    options: {
      ...parsed.options,
      noEmit: false,
      declaration: true,
      emitDeclarationOnly: true,
      declarationMap: false,
      sourceMap: false,
      outDir,
    },
  });
  const emitted = program.emit();
  const diagnostics = [...ts.getPreEmitDiagnostics(program), ...emitted.diagnostics];
  if (diagnostics.length > 0 || emitted.emitSkipped) {
    throw new Error(ts.formatDiagnostics(diagnostics, {
      getCanonicalFileName: (name) => name,
      getCurrentDirectory: () => dir,
      getNewLine: () => '\n',
    }));
  }
}

/**
 * API Extractor parses a tsconfig file without telling the compiler where it lives, so `types: ["node"]`
 * would be looked up from the working directory. An explicit `typeRoots` makes it independent of it.
 */
function analysisTsconfig(dir: string): Record<string, unknown> {
  const read = ts.readConfigFile(join(dir, 'tsconfig.json'), ts.sys.readFile);
  if (read.error) throw new Error(ts.flattenDiagnosticMessageText(read.error.messageText, '\n'));
  const config = toJson(read.config);
  const compilerOptions = isJsonObject(config) ? config['compilerOptions'] : undefined;
  if (!isJsonObject(compilerOptions)) throw new Error(`${join(dir, 'tsconfig.json')} has no compilerOptions object`);
  return { compilerOptions: { ...compilerOptions, typeRoots: [join(dir, 'node_modules', '@types')] } };
}

async function reportOf(pkg: PublicPackage, scratch: string): Promise<ApiReport> {
  const cache = join(scratch, pkg.name.replace(/^@[^/]+\//, ''));
  const dts = join(cache, 'dts');
  await rm(cache, { recursive: true, force: true });
  await mkdir(cache, { recursive: true });
  emitDeclarations(pkg.dir, dts);

  const file = `${pkg.name.replace(/^@[^/]+\//, '')}.api.md`;
  const config = ExtractorConfig.prepare({
    configObjectFullPath: join(pkg.dir, 'api-extractor.json'),
    packageJsonFullPath: join(pkg.dir, 'package.json'),
    configObject: {
      projectFolder: pkg.dir,
      mainEntryPointFilePath: join(dts, 'index.d.ts'),
      compiler: { overrideTsconfig: analysisTsconfig(pkg.dir) },
      apiReport: {
        enabled: true,
        reportFileName: file,
        reportFolder: cache,
        reportTempFolder: cache,
      },
      docModel: { enabled: false },
      dtsRollup: { enabled: false },
      tsdocMetadata: { enabled: false },
      newlineKind: 'lf',
      messages: {
        extractorMessageReporting: {
          'ae-missing-release-tag': { logLevel: ExtractorLogLevel.None, addToApiReportFile: false },
        },
      },
    },
  });

  const errors: string[] = [];
  const result = Extractor.invoke(config, {
    localBuild: true,
    showVerboseMessages: false,
    messageCallback: (message: ExtractorMessage) => {
      if (message.logLevel === ExtractorLogLevel.Error) errors.push(message.text);
      message.handled = true;
    },
  });
  if (!result.succeeded) throw new Error(errors.join('\n'));

  const markdown = (await readFile(join(cache, file), 'utf8')).replace(/\r\n/g, '\n');
  return { package: pkg.name, file, markdown };
}

/** One report per public package under `<root>/packages`, sorted by package name. */
export async function apiReports(root: string): Promise<readonly ApiReport[]> {
  const packages = await publicPackages(root);
  await mkdir(CACHE, { recursive: true });
  const scratch = await mkdtemp(join(CACHE, 'run-'));
  try {
    const reports: ApiReport[] = [];
    for (const pkg of packages) reports.push(await reportOf(pkg, scratch));
    return reports;
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
}
