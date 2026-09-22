# AGENTS.md

Standing rules for agents working in this repository, set by the repository owner.

This file holds rules only. It doesn't describe the project or record plans, work in progress or
history. Descriptions of the project go in documentation. Plans, work in progress and history go in
agent memory or agent notes.

## 1. Working with the owner

1.1. The owner is the lead engineer and makes the decisions. The agent carries out the work.

1.2. Don't plan, design or direct unless asked, and don't tell the owner what to do next.

1.3. Wait for instructions. Write code when told to write code.

1.4. When a decision belongs to the owner, ask instead of choosing and carrying on.

1.5. The owner decides the project's structure: the directory and module layout, the files, and how
responsibilities are split between them. Don't propose or introduce a structure unprompted.

## 2. Writing style

This section covers all text written in this repository: documentation (section 3, which includes
code comments), error messages, commit messages (format in section 5) and agent notes.

2.1. Write plainly and naturally, the way an engineer explains something to a colleague.

2.2. Use short, direct sentences and common words.

2.3. Every sentence carries information. No filler, no preamble, no restating what was just said.

2.4. No literary or dramatic phrasing: no aphorisms, rhetorical contrasts, personification,
moralizing or punchlines.

2.5. Use lists and tables for facts, values and steps instead of long paragraphs.

2.6. Examples of the style to avoid, and a plain version of each:

| avoid | plain |
|---|---|
| "Degraded is not dead. ... That is the entire premise of the project, so it would be strange to abort." | "If a backhaul fails to start, the daemon logs the error and runs on the others." |
| "a version is a claim, a hash is the thing itself" | "Builds are identified by the SHA-256 of the binary." |
| "Agreement beats proximity." | "Every node uses the network's agreed DERP region, even when another region is closer." |
| "Downloading fifteen megabytes because somebody ran `meshctl peers` would be rude." | "The CLI checks the update manifest but never downloads binaries on its own." |

## 3. Documentation

Documentation is any text a person reads to understand or use the project: READMEs, files in
`docs/`, help text, API and configuration descriptions, and code comments.

3.1. Code comments are documentation. Every rule in this section applies to them.

3.2. Documentation is written for people: the owner and anyone else who reads the repository.

3.3. It describes the current state: what something is, what it does, how it behaves, how to use
and configure it, and its interfaces, formats and limits.

3.4. It doesn't explain the decisions behind that state. No rationale, no alternatives that were
considered or rejected, no trade-off discussion.

3.5. It doesn't record history. No "used to", "no longer", "was changed to", "originally" or "the
old version", no changelog narration, no list of fixed bugs.

3.6. It doesn't hold development memory: no debugging stories, lessons learned, failed attempts,
time spent, test or verification logs, or measurements from development runs.

3.7. What 3.4 to 3.6 rule out belongs in agent memory or agent notes (section 4), never in
documentation.

3.8. A constraint that holds now is current state, and can be documented when a reader needs it.
State it as a fact in the present tense. Write: "The HTTP/3 control stream must stay open for the
whole connection. If it closes, the server closes the connection." Not: "Dropping the stream handle
killed the connection, and it took a day to find."

3.9. Write in the present tense.

3.10. When the code changes, update the affected documentation, code comments included, so it
describes the new state. Don't add notes about what changed.

3.11. Write a code comment only when it tells the reader something the code doesn't: what the code
does, or what must hold, when that isn't clear from the code itself.

## 4. Agent notes and memory

4.1. Agent notes and agent memory hold what documentation and this file don't: decisions and their
reasons, history, lessons, plans, work in progress, and context for future work.

4.2. Write agent notes for a reader with no context: self-contained, with exact values, names and
references.

4.3. Agent notes must be accurate without anyone reviewing them. Check claims against the source
before writing them down, and mark anything inferred or unverified.

4.4. Agent notes follow section 2.

4.5. Don't move agent-note content into documentation.

## 5. Commits

5.1. Commit messages follow the format of the existing history.

5.2. The subject line is lowercase and in the imperative, with no trailing period, and at most 72
characters.

5.3. The subject starts with the area and a colon when the change is limited to one area (`ci:`,
`tun:`, `node:`). Leave the prefix off when the change spans areas.

5.4. After a blank line, the body is prose paragraphs wrapped at 80 columns, saying what changed and
why.

5.5. Commit messages and pull request descriptions carry no Co-Authored-By or other attribution
lines, and no session links.
