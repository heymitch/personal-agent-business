# operator-skills

Your skills live here. There is no fixed library and nothing to write up front.

You build skills on your OWN Hermes agent (whatever your business needs: a
scorecard, a follow-up writer, a research pass). The `agentize` pipeline then
ships those skills to every client agent you mint:

```
scripts/agentize.sh --scan-skills                     # discover your skills
scripts/agentize.sh --package-skills --source <dir>   # tar them, no transform
scripts/agentize.sh --load-skills --target <client>   # rsync onto a client agent
```

By default `--scan-skills` reads the skills on your OWN box at
`/home/hermes/.hermes/skills` over SSH (the same directory `move_up.sh` lifts
your local Hermes skills into). Pass `--source <dir>` to scan a local folder
instead (each skill is a folder containing a `SKILL.md`).

The narrated operator flow is `.claude/commands/agentize-skills.md`.

This folder is a staging/reference location. Drop a skill folder here (one
folder per skill, each with a `SKILL.md`) and `--scan-skills --source operator-skills`
will pick it up. The pipeline never edits your skill contents; it only archives
and ships them.
