# /agentize-skills

Ship the operator's OWN skills to the client agents they mint. The operator builds
skills on their OWN Hermes agent (whatever their business needs); this flow scans
those skills, packages them as portable bundles, and loads them onto a client agent.

There is NO fixed skill library. The skills are operator-authored. This command is the
delivery mechanism: build a skill once on your own agent, ship it to every client.

You are the guide. Walk the operator through three stages, one at a time. You run the
scripts; you own the judgment (which skills to ship to which client). No key, and no
SSH key path, is ever printed back.

---

## What "agentize" does (the operator's mental model)

```
your Hermes agent                          a freshly minted client agent
/home/hermes/.hermes/skills/   --scan-->   (none yet)
   <your-skill-a>/             --package-> <your-skill-a>.tgz
   <your-skill-b>/             --load----> /home/hermes/.hermes/skills/
                                              <your-skill-a>/
                                              <your-skill-b>/
```

The client agent's skills directory is the SAME path your own agent uses
(`/home/hermes/.hermes/skills/`, the directory `move_up.sh` lifts your local skills
into). Loading is a straight copy plus a gateway restart. Your skill contents are never
edited; they are archived verbatim and shipped.

---

## Step 1: scan (free, touches nothing)

Discover the skills on your OWN box. By default the scanner reads
`/home/hermes/.hermes/skills/` on your operator box over SSH (using `AGENT_IP` and
`SSH_KEY` from `.env`):

```
scripts/agentize.sh --scan-skills --dry-run
```

To preview a LOCAL folder instead (each skill is a folder with a `SKILL.md`):

```
scripts/agentize.sh --scan-skills --source operator-skills --dry-run
```

Read the discovered skill names back to the operator and confirm the count:

```
SKILLS-SCANNED count=<n>
```

If `count=0`, the operator has not built any skills yet (or `--source` points at the
wrong folder). Point them at their own agent: they build a skill there first, then come
back. Do not invent skills for them.

---

## Step 1b: define your AGENT PROFILES (the named builds you sell)

A profile is a NAME + a set of YOUR skill ids (+ an optional description). It is the
"build" the operator picks when minting a client agent. Profiles are operator-defined
(there is no fixed catalog); they live in `config/agent-profiles.json` (gitignored;
copy the shape from `config/agent-profiles.example.json`).

Interview the operator ONE question at a time off the scanned list:

1. "Of the skills I just found, which do you actually want to ship to clients?"
   (confirm the include set; do not assume all of them).
2. "Let's group them into builds. What is your default build, and which of those
   skills does it include?" (name it, e.g. "Starter").
3. "Any other builds you sell to different clients?" (e.g. a bigger "Pro"). Repeat
   until they are done. Pick a sensible `defaultProfile` (usually the first/smallest).

Write the answers to `config/agent-profiles.json` in this shape:

```json
{
  "profiles": [
    { "name": "Starter", "skills": ["<skill-id>", "..."], "description": "..." },
    { "name": "Pro", "skills": ["<skill-id>", "..."] }
  ],
  "defaultProfile": "Starter"
}
```

Those profiles do three things automatically:

- the console New-agent form RENDERS them (pick a profile = a build),
- the mint records the chosen profile's skills (the default profile is the FLOOR when
  no profile is chosen),
- `scripts/agentize.sh --load-skills --target <new agent> --profile <name>` (or
  `--defaults` for the default profile) ships exactly that build onto a fresh agent.

---

## Step 2: package (writes portable bundles)

Tar each scanned skill into a portable bundle in the staging dir
(`.agentize-staging/` by default, gitignored). Preview first:

```
scripts/agentize.sh --package-skills --source <skills-dir> --dry-run
```

Then package for real:

```
scripts/agentize.sh --package-skills --source <skills-dir>
```

Capture:

```
SKILLS-PACKAGED count=<n>
```

Packaging is a straight archive (`tar -c`) of each skill folder. It does NOT transform
or rewrite any skill content. The bundle is a self-contained `SKILL.md` plus that
skill's resources, ready to drop onto any agent.

> Note: to package skills that live ONLY on the box, pull them down to a local folder
> first (e.g. `scp` the skill dirs to `operator-skills/`), then `--package-skills
> --source operator-skills`. Packaging archives local folders.

---

## Step 3: load onto a client agent (over SSH)

Ship the packaged bundles onto a freshly minted client agent and restart its gateway so
the skills go live. Preview first (confirm the right client target):

```
scripts/agentize.sh --load-skills --target <client_ip_or_host> --source <skills-dir> --dry-run
```

Then load for real:

```
scripts/agentize.sh --load-skills --target <client_ip_or_host> --source <skills-dir>
```

Capture:

```
SKILLS-LOADED count=<n>
```

This rsyncs each bundle to the client's `/home/hermes/.hermes/skills/`, unpacks it,
fixes ownership to `hermes`, and restarts the client agent's gateway. The `--target` is
the client agent you just minted (its box IP or host).

---

## Step 4: verify and hand off

- Confirm the client's `SKILLS-LOADED count` matches the `SKILLS-PACKAGED count`.
- On the client agent, confirm a loaded skill is discoverable (ask the agent to list
  its skills, or check `/home/hermes/.hermes/skills/` over SSH).

Tell the operator:

> "Your skills are live on the client's agent. Anytime you build a new skill on your own
> agent, run /agentize-skills again to ship it. Build once, deliver to every client."
