#!/usr/bin/env node
/**
 * self-driving-agents — install a self-driving agent from a directory.
 *
 * npx @vectorize-io/self-driving-agents install <dir> --harness openclaw [--agent <name>]
 *
 * Directory layout:
 *   bank-template.json   — optional: bank config + mental models + directives
 *   content/             — optional: reference docs to ingest (.md, .txt, etc.)
 *
 * The CLI copies files to the agent workspace. The harness plugin handles
 * bank creation, template import, and content ingestion on first session.
 */

import { readFileSync, writeFileSync, copyFileSync, mkdirSync, existsSync, readdirSync } from "fs";
import { join, resolve, extname, basename } from "path";
import { homedir } from "os";

// ── Skill ───────────────────────────────────────────────

const SKILL_MD = `---
name: agent-knowledge
description: Your long-term knowledge pages. Read them at session start. Create new pages for recurring topics. Pages auto-update from your conversations.
---

# Agent Knowledge

You have knowledge pages that persist across sessions and auto-update from your conversations.

**How it works:** Conversations are retained into Hindsight. The system extracts observations and rebuilds each page via its "source query." You create pages; the system maintains them.

## At session start

Call \`agent_knowledge_list_pages\` to see what pages exist, then \`agent_knowledge_get_page\` for each one you need.

## Tools

- \`agent_knowledge_list_pages()\` — list page IDs and names (no content)
- \`agent_knowledge_get_page(page_id)\` — read the full content of a page
- \`agent_knowledge_create_page(page_id, name, source_query)\` — create a page
- \`agent_knowledge_update_page(page_id, name?, source_query?)\` — update a page
- \`agent_knowledge_delete_page(page_id)\` — delete a page
- \`agent_knowledge_recall(query)\` — search all memories
- \`agent_knowledge_ingest(title, content)\` — upload raw content (never summarize)

## Creating pages

Create when you learn something durable — preferences, procedures, performance data.
The source_query is a question the system re-asks to rebuild the page.

Examples:
- "What are the user's preferences for tone, length, and formatting?"
- "What strategies have performed well or poorly? Include numbers."
- "What are the best practices for [topic], preferring our data over generic advice?"

## Rules

- Pages update automatically — don't edit content directly
- State preferences clearly in responses so the system captures them
- Create pages silently
- Prefer fewer broad pages over many narrow ones
`;

// ── Main ────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2);

  if (args.length < 1 || args[0] === "--help" || args[0] === "-h") {
    console.log(`Usage: npx @vectorize-io/self-driving-agents install <dir> --harness <harness> [--agent <name>]

Arguments:
  <dir>              Agent directory (contains optional bank-template.json + content/)

Options:
  --harness <h>      Required. openclaw | hermes | claude-code
  --agent <name>     Agent name (defaults to directory name)`);
    process.exit(0);
  }

  let dirArg = args[0] === "install" ? args[1] : args[0];
  const restArgs = args[0] === "install" ? args.slice(2) : args.slice(1);

  if (!dirArg) {
    console.error("Error: directory argument required");
    process.exit(1);
  }

  let harness: string | undefined;
  let agentName: string | undefined;

  for (let i = 0; i < restArgs.length; i++) {
    if (restArgs[i] === "--harness" && restArgs[i + 1]) harness = restArgs[++i];
    else if (restArgs[i] === "--agent" && restArgs[i + 1]) agentName = restArgs[++i];
  }

  if (!harness) {
    console.error("Error: --harness is required (openclaw | hermes | claude-code)");
    process.exit(1);
  }

  const dir = resolve(dirArg);
  if (!existsSync(dir)) {
    console.error(`Error: directory not found: ${dir}`);
    process.exit(1);
  }

  const agentId = agentName || basename(dir);

  // Resolve workspace
  let workspaceDir: string;
  switch (harness) {
    case "openclaw":
      workspaceDir = join(homedir(), ".hindsight-agents", "openclaw", agentId);
      break;
    case "hermes":
      workspaceDir = join(homedir(), ".hermes");
      break;
    case "claude-code":
      workspaceDir = join(homedir(), ".claude");
      break;
    default:
      console.error(`Unknown harness: ${harness}. Supported: openclaw, hermes, claude-code`);
      process.exit(1);
  }

  console.log(`Installing '${agentId}' on ${harness}`);
  console.log(`  Source:    ${dir}`);
  console.log(`  Workspace: ${workspaceDir}`);
  console.log();

  mkdirSync(workspaceDir, { recursive: true });

  // Copy bank-template.json if exists
  const templateSrc = join(dir, "bank-template.json");
  const templateDst = join(workspaceDir, ".hindsight", "bank-template.json");
  if (existsSync(templateSrc)) {
    mkdirSync(join(workspaceDir, ".hindsight"), { recursive: true });
    copyFileSync(templateSrc, templateDst);
    console.log("Copied bank-template.json");
  }

  // Copy content/ if exists
  const contentSrc = join(dir, "content");
  if (existsSync(contentSrc)) {
    const contentDst = join(workspaceDir, ".hindsight", "content");
    mkdirSync(contentDst, { recursive: true });
    const exts = new Set([".md", ".txt", ".html", ".json", ".csv", ".xml"]);
    const files = readdirSync(contentSrc).filter((f) => exts.has(extname(f).toLowerCase()));
    for (const file of files) {
      copyFileSync(join(contentSrc, file), join(contentDst, file));
    }
    console.log(`Copied ${files.length} content file(s)`);
  }

  // Install skill
  const skillDir = join(workspaceDir, "skills", "agent-knowledge");
  mkdirSync(skillDir, { recursive: true });
  writeFileSync(join(skillDir, "SKILL.md"), SKILL_MD);
  console.log("Skill installed.");

  // Create harness agent
  if (harness === "openclaw") {
    try {
      const { execSync } = await import("child_process");
      const listOut = execSync("openclaw agents list --json 2>/dev/null", { encoding: "utf-8" });
      const agents = JSON.parse(listOut).agents || [];
      if (!agents.some((a: any) => a.name === agentId)) {
        execSync(`openclaw agents add ${agentId} --workspace ${workspaceDir} --non-interactive`, { stdio: "pipe" });
        console.log(`Created agent '${agentId}'.`);
      } else {
        console.log(`Agent '${agentId}' already exists.`);
      }
    } catch {
      console.log(`Note: create agent manually: openclaw agents add ${agentId} --workspace ${workspaceDir} --non-interactive`);
    }
  }

  // Patch startup file
  const startupFile = harness === "openclaw"
    ? join(workspaceDir, "AGENTS.md")
    : harness === "hermes"
      ? (agentId === "default" ? join(workspaceDir, "SOUL.md") : join(homedir(), ".hermes", "profiles", agentId, "SOUL.md"))
      : undefined;

  const startupPatch = harness === "openclaw"
    ? '5. Read `skills/agent-knowledge/SKILL.md` and **execute its mandatory startup sequence**'
    : "## Mandatory: Agent Knowledge\n\nAt session start, load the `agent-knowledge` skill and execute its startup sequence.";

  if (startupFile && existsSync(startupFile)) {
    let text = readFileSync(startupFile, "utf-8");
    if (!text.includes("agent-knowledge")) {
      if (text.includes("Don't ask permission.")) {
        text = text.replace("Don't ask permission. Just do it.", `${startupPatch}\n\nDon't ask permission. Just do it.`);
      } else {
        text += `\n\n${startupPatch}\n`;
      }
      writeFileSync(startupFile, text);
      console.log("Startup patched.");
    }
  }

  console.log();
  console.log(`'${agentId}' installed.`);
  console.log("The plugin will import the template and content on first session.");
  if (harness === "openclaw") console.log("  Restart gateway: openclaw gateway restart");
  if (harness === "hermes") console.log(`  Chat: hermes${agentId !== "default" ? ` --profile ${agentId}` : ""}`);
}

main().catch((err) => {
  console.error(`Error: ${err.message}`);
  process.exit(1);
});
