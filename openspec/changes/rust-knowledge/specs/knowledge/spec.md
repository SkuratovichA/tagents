## MODIFIED Requirements

### Requirement: One shared server per environment
Every client of the same environment SHALL be served by one daemon per program, and clients whose environments differ SHALL get separate daemons that answer from their own documents. The environment is `HOME`, `TAGENTS_CONFIG_DIR`, `XDG_CONFIG_HOME`, `TAGENTS_KNOWLEDGE_DIR`, `TAGENTS_KNOWLEDGE_DB`, `TAGENTS_KNOWLEDGE_USAGE_DB` and `CLAUDE_HOMES`, plus the build of the program that runs. The node program and the native program are two programs and never share a daemon.

#### Scenario: Two sessions, one daemon
- **WHEN** two sessions start at the same moment in the same environment
- **THEN** one daemon serves both, and it outlives them

#### Scenario: Different documents
- **WHEN** one session sets `TAGENTS_KNOWLEDGE_DIR` to folder A and another to folder B
- **THEN** each daemon lists only its own folder's documents

#### Scenario: Different usage stores
- **WHEN** one session sets `TAGENTS_KNOWLEDGE_USAGE_DB` to file A and another to file B, and each reads a document through its daemon
- **THEN** the two sessions get separate daemons, and each read is recorded in its own file only

#### Scenario: Two programs
- **WHEN** a node daemon and a native daemon are started in one environment
- **THEN** they listen on two sockets, and each serves the clients that reached it

### Requirement: One bad client does not stop the others
A client that sends rubbish (text that is not JSON, JSON that is not a request, bytes that are not text, an unknown method, a cut-off line) or whose connection fails while it is set up SHALL cost only its own connection. An exception or rejection nobody caught SHALL be reported on stderr as a line starting `tagents-knowledge:` that names what failed, followed by the error's detail, a stack where the program has one, and the daemon SHALL go on serving. A signal SHALL stop it.

#### Scenario: Garbage, then a real client
- **WHEN** a client sends rubbish and disconnects, and a session then connects
- **THEN** the daemon pid is unchanged and the session lists the six tools
