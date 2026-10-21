import { access, lstat, readFile, realpath } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// @spec AGENT-INSTRUCTION-002
const CANONICAL_FILE = "CLAUDE.md";
const SYMLINKS = [ "AGENTS.md", ".github/copilot-instructions.md" ];
const REQUIRED_HEADINGS = [ "Start here", "Work by task", "Safety boundaries", "LID" ];
const REQUIRED_LINKS = [
  "docs/high-level-design.md",
  "docs/intent/README.md",
  "docs/lid/workflow.md",
  "docs/LLM_STYLE_GUIDE.md",
  "docs/STYLE_GUIDE.md",
  "docs/intent/toolchain-pin-management/"
];

export async function validateInstructionMap(root) {
  const canonicalPath = resolve(root, CANONICAL_FILE);
  const issues = [];
  const contents = await readCanonicalFile(canonicalPath, issues);
  if (!contents) return issues;

  await validateSymlinks(root, canonicalPath, issues);
  validateHeadings(contents, issues);
  await validateRequiredLinks(root, contents, issues);
  await validateLocalLinks(root, canonicalPath, contents, issues);
  return [ ...new Set(issues) ];
}

async function readCanonicalFile(path, issues) {
  try {
    return await readFile(path, "utf8");
  } catch {
    issues.push(`Missing instruction entry point: ${CANONICAL_FILE}`);
    return null;
  }
}

async function validateSymlinks(root, canonicalPath, issues) {
  await Promise.all(SYMLINKS.map(async (link) => {
    const path = resolve(root, link);
    const valid = await pointsToCanonicalFile(path, canonicalPath);
    if (!valid) issues.push(`Instruction entry point must symlink to ${CANONICAL_FILE}: ${link}`);
  }));
}

async function pointsToCanonicalFile(path, canonicalPath) {
  try {
    return (await lstat(path)).isSymbolicLink() && await realpath(path) === await realpath(canonicalPath);
  } catch {
    return false;
  }
}

function validateHeadings(contents, issues) {
  REQUIRED_HEADINGS.forEach((heading) => {
    if (!contents.includes(`## ${heading}`)) issues.push(`Missing instruction heading: ${heading}`);
  });
}

async function validateRequiredLinks(root, contents, issues) {
  await Promise.all(REQUIRED_LINKS.map(async (link) => {
    if (!contents.includes(`](${link})`)) {
      issues.push(`Missing required navigation link: ${link}`);
      return;
    }
    if (!await pathExists(resolve(root, link))) issues.push(`Missing local link target: ${link}`);
  }));
}

async function validateLocalLinks(root, canonicalPath, contents, issues) {
  const links = [ ...contents.matchAll(/(?<!!)[^!]?\[[^\]]*\]\(([^)]+)\)/g) ]
    .map((match) => localTarget(match[1]))
    .filter(Boolean);
  await Promise.all(links.map(async (target) => {
    const path = resolve(dirname(canonicalPath), target);
    if (!await pathExists(path)) issues.push(`Missing local link target: ${target}`);
  }));
}

function localTarget(link) {
  const target = link.trim().replace(/^<|>$/g, "").split("#", 1)[0];
  return target && !/^[a-z][a-z+.-]*:/i.test(target) ? target : null;
}

async function pathExists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const issues = await validateInstructionMap(process.cwd());
  if (issues.length > 0) {
    console.error(issues.join("\n"));
    process.exitCode = 1;
  }
}
