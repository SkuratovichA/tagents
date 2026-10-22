// The CLI's human strings. Anything a machine reads — `--json` output, the
// text the MCP tools return — never comes from here.
export const en = {
  usage: [
    'usage: tagents-knowledge <command>',
    '',
    '  index [--dir D] [--db F] [--full]',
    '  search <query…> [--tag T] [--type T] [--kind K] [--limit N] [--json]',
    '  show <id[#heading]> [--dir D]',
    '  list [--type T] [--kind K] [--tag T] [--json]',
    '  lint [--dir D]',
    '  mcp',
    '  serve [--idle S] [--foreground] [--socket P]',
    '',
    'exit: 0 ok · 1 error · 2 usage · 4 nothing found',
  ].join('\n'),
  unknownCommand: 'unknown command: {{command}}',
  missingOption: 'missing required argument {{option}}',
  noDir: [
    'no knowledge directory: set TAGENTS_KNOWLEDGE_DIR, pass --dir, or add to {{config}}',
    '',
    '  knowledge:',
    '    dir: ~/git/personal/knowledge',
  ].join('\n'),
  missingDir: 'knowledge directory {{dir}} does not exist',
  indexed:
    'indexed {{db}}: {{added}} new, {{changed}} changed, {{unchanged}} unchanged, {{removed}} removed',
  indexErrors: '{{count}} file(s) could not be read; run lint',
  notIndexed: 'index {{db}} is empty — run: tagents-knowledge index',
  noHits: 'nothing matches {{query}}',
  unknownId: 'no document with id {{id}}',
  unknownHeading: 'document {{id}} has no section "{{heading}}"',
  noDocs: 'no documents in {{dir}}',
  lintClean: '{{count}} document(s) in {{dir}}: no problems',
  lintProblems: '{{count}} problem(s) in {{dir}}',
  issueFrontmatter: 'invalid frontmatter — {{detail}}',
  issueStem: 'id "{{id}}" must equal the filename stem "{{stem}}"',
  issueDuplicateId: 'duplicate id "{{id}}", already used by {{other}}',
  issueStale: 'updated {{updated}} is older than the newest commit touching the file ({{commit}})',
  issueGenerated: 'generated_from {{source}} changed on {{changed}}, after updated {{updated}}',
  issueDeadLink: 'dead link [[{{target}}]]',
  summaryIndex: 'brings the index in line with the folder; --full rebuilds it from nothing',
  summarySearch:
    'prints one line per hit: id#heading, score and snippet; --type filters by type (--kind is its deprecated alias); deprecated documents come last',
  summaryShow: 'prints the markdown of a document, or of one section of it',
  summaryList:
    'prints one line per document: id, type, updated, title and tags; --type filters by type (--kind is its deprecated alias); deprecated documents come last',
  summaryLint: 'checks the claims each document makes about itself',
  summaryMcp: 'serves the knowledge tools over stdio as an MCP server',
  summaryServe:
    'starts the shared MCP server for this environment if it is not running and prints its unix socket; --idle S is how many seconds without a client before it exits (default 600); --foreground runs the server in this process, on --socket P',
  badIdle: '--idle must be a positive number of seconds',
  serveFailed: 'could not start the shared knowledge server: {{reason}}',
} as const;
