import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { validateInstructionMap } from "../../scripts/check_instruction_links.mjs";

// @spec AGENT-INSTRUCTION-001 AGENT-INSTRUCTION-002
const requiredHeadings = [ "Start here", "Work by task", "Safety boundaries", "LID" ];
const requiredLinks = [
  "docs/high-level-design.md",
  "docs/intent/README.md",
  "docs/lid/workflow.md",
  "docs/LLM_STYLE_GUIDE.md",
  "docs/STYLE_GUIDE.md",
  "docs/intent/toolchain-pin-management/"
];

test("accepts the instruction entry points and navigation routes", async (t) => {
  const root = await createFixture();
  t.after(() => rm(root, { recursive: true, force: true }));

  assert.deepEqual(await validateInstructionMap(root), []);
});

test("reports a missing local navigation target", async (t) => {
  const root = await createFixture({ omit: "docs/STYLE_GUIDE.md" });
  t.after(() => rm(root, { recursive: true, force: true }));

  assert.deepEqual(await validateInstructionMap(root), [ "Missing local link target: docs/STYLE_GUIDE.md" ]);
});

async function createFixture({ omit } = {}) {
  const root = await mkdtemp(join(tmpdir(), "instruction-links-"));
  const targets = [ ...new Set(requiredLinks) ].filter((target) => target !== omit);

  await Promise.all(targets.map((target) => createTarget(root, target)));
  await writeFile(join(root, "CLAUDE.md"), instructionFile());
  await symlink("CLAUDE.md", join(root, "AGENTS.md"));
  await mkdir(join(root, ".github"));
  await symlink("../CLAUDE.md", join(root, ".github", "copilot-instructions.md"));
  return root;
}

async function createTarget(root, target) {
  const path = join(root, target);
  await mkdir(path.endsWith("/") ? path : join(path, ".."), { recursive: true });
  await writeFile(path.endsWith("/") ? join(path, "README.md") : path, "# Target\n");
}

function instructionFile() {
  const headings = requiredHeadings.map((heading) => `## ${heading}`).join("\n\n");
  const links = requiredLinks.map((target) => `[${target}](${target})`).join("\n");
  return `${headings}\n\n${links}\n`;
}
