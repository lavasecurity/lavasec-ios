#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { addedLinesFromUnifiedDiff } from "./unified-diff.mjs";
import { splitYAMLDocumentComments } from "./yaml-comment-utils.mjs";

const repoRoot = process.cwd();
const swiftScopeRoots = [
  "LavaSecApp",
  "LavaSecTunnel",
  "LavaSecWidget",
  "LavaSecIntents",
  "Shared",
  "Sources",
];
const deferredMarkers = ["TO" + "DO", "FIX" + "ME"];
const gitOutputMaxBuffer = 32 * 1024 * 1024;

function walkSwiftFiles(relativeRoot) {
  const absoluteRoot = path.join(repoRoot, relativeRoot);
  if (!fs.existsSync(absoluteRoot)) {
    return [];
  }

  const files = [];
  const visit = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        visit(entryPath);
      } else if (entry.isFile() && entry.name.endsWith(".swift")) {
        files.push(path.relative(repoRoot, entryPath).split(path.sep).join("/"));
      }
    }
  };
  visit(absoluteRoot);
  return files;
}

function swiftCommentEntries(source) {
  const entries = [];
  let blockDepth = 0;
  let insideMultilineString = false;

  for (const [lineIndex, line] of source.split(/\r?\n/).entries()) {
    let index = 0;
    let blockFragment = "";

    while (index < line.length) {
      if (blockDepth > 0) {
        if (line.startsWith("/*", index)) {
          blockDepth += 1;
          blockFragment += "/*";
          index += 2;
        } else if (line.startsWith("*/", index)) {
          blockDepth -= 1;
          index += 2;
          if (blockDepth === 0 && blockFragment.trim()) {
            entries.push({ line: lineIndex + 1, text: blockFragment });
            blockFragment = "";
          }
        } else {
          blockFragment += line[index];
          index += 1;
        }
        continue;
      }

      if (insideMultilineString) {
        const closingIndex = line.indexOf('"""', index);
        if (closingIndex === -1) {
          break;
        }
        insideMultilineString = false;
        index = closingIndex + 3;
        continue;
      }

      if (line.startsWith('"""', index)) {
        insideMultilineString = true;
        index += 3;
        continue;
      }

      if (line[index] === '"') {
        index += 1;
        while (index < line.length) {
          if (line[index] === "\\") {
            index += 2;
          } else if (line[index] === '"') {
            index += 1;
            break;
          } else {
            index += 1;
          }
        }
        continue;
      }

      if (line.startsWith("//", index)) {
        entries.push({ line: lineIndex + 1, text: line.slice(index + 2) });
        break;
      }
      if (line.startsWith("/*", index)) {
        blockDepth = 1;
        blockFragment = "";
        index += 2;
        continue;
      }
      index += 1;
    }

    if (blockDepth > 0 && blockFragment.trim()) {
      entries.push({ line: lineIndex + 1, text: blockFragment });
    }
  }

  return entries;
}

function yamlCommentEntries(source) {
  const entries = [];
  for (const [lineIndex, { comment }] of splitYAMLDocumentComments(source).entries()) {
    if (comment !== undefined) {
      entries.push({ line: lineIndex + 1, text: comment });
    }
  }
  return entries;
}

function canStartBareSwiftRegex(source, slashIndex) {
  let previousIndex = slashIndex - 1;
  while (previousIndex >= 0 && /\s/.test(source[previousIndex])) {
    previousIndex -= 1;
  }
  if (previousIndex < 0 || "=([{,:;!?&|^~<>".includes(source[previousIndex])) {
    return true;
  }

  const precedingWord = source.slice(0, previousIndex + 1).match(/[A-Za-z_][A-Za-z0-9_]*$/)?.[0];
  return ["case", "in", "return", "throw", "where"].includes(precedingWord);
}

function swiftCodeWithoutCommentsAndStrings(source) {
  const code = source.split("");
  const mask = (index) => {
    if (code[index] !== "\n" && code[index] !== "\r") {
      code[index] = " ";
    }
  };
  let index = 0;

  while (index < source.length) {
    if (source.startsWith("//", index)) {
      while (index < source.length && source[index] !== "\n") {
        mask(index);
        index += 1;
      }
      continue;
    }

    if (source.startsWith("/*", index)) {
      let depth = 0;
      while (index < source.length) {
        if (source.startsWith("/*", index)) {
          depth += 1;
          mask(index);
          mask(index + 1);
          index += 2;
        } else if (source.startsWith("*/", index)) {
          depth -= 1;
          mask(index);
          mask(index + 1);
          index += 2;
          if (depth === 0) {
            break;
          }
        } else {
          mask(index);
          index += 1;
        }
      }
      continue;
    }

    let hashCount = 0;
    while (source[index + hashCount] === "#") {
      hashCount += 1;
    }
    const regexSlashIndex = index + hashCount;
    if (source[regexSlashIndex] === "/"
        && (hashCount > 0 || canStartBareSwiftRegex(source, regexSlashIndex))) {
      const openingLength = hashCount + 1;
      for (let offset = 0; offset < openingLength; offset += 1) {
        mask(index + offset);
      }
      index += openingLength;
      let insideCharacterClass = false;

      while (index < source.length) {
        if (hashCount === 0 && source[index] === "\\") {
          mask(index);
          index += 1;
          if (index < source.length) {
            mask(index);
            index += 1;
          }
          continue;
        }
        if (source[index] === "[") {
          insideCharacterClass = true;
        } else if (source[index] === "]") {
          insideCharacterClass = false;
        }

        const closingDelimiter = `/${"#".repeat(hashCount)}`;
        if (!insideCharacterClass && source.startsWith(closingDelimiter, index)) {
          for (let offset = 0; offset < closingDelimiter.length; offset += 1) {
            mask(index + offset);
          }
          index += closingDelimiter.length;
          break;
        }
        mask(index);
        index += 1;
      }
      continue;
    }

    const quoteIndex = index + hashCount;
    const quoteLength = source.startsWith('"""', quoteIndex)
      ? 3
      : source[quoteIndex] === '"' ? 1 : 0;
    if (quoteLength > 0) {
      const closingDelimiter = `${'"'.repeat(quoteLength)}${"#".repeat(hashCount)}`;
      const openingLength = hashCount + quoteLength;
      for (let offset = 0; offset < openingLength; offset += 1) {
        mask(index + offset);
      }
      index += openingLength;

      while (index < source.length) {
        if (source.startsWith(closingDelimiter, index)) {
          for (let offset = 0; offset < closingDelimiter.length; offset += 1) {
            mask(index + offset);
          }
          index += closingDelimiter.length;
          break;
        }
        if (hashCount === 0 && source[index] === "\\") {
          mask(index);
          index += 1;
          if (index < source.length) {
            mask(index);
            index += 1;
          }
          continue;
        }
        mask(index);
        index += 1;
      }
      continue;
    }

    index += 1;
  }

  return code.join("");
}

function closingBraceIndex(code, openingBraceIndex) {
  let depth = 0;
  for (let index = openingBraceIndex; index < code.length; index += 1) {
    if (code[index] === "{") {
      depth += 1;
    } else if (code[index] === "}") {
      depth -= 1;
      if (depth === 0) {
        return index;
      }
    }
  }
  return undefined;
}

function directTestMethods(code, openingBraceIndex, closingBrace) {
  const body = code.slice(openingBraceIndex + 1, closingBrace);
  const methods = [];
  const methodPattern = /\bfunc\s+(test[A-Za-z0-9_]+)\s*\(/g;
  let cursor = 0;
  let depth = 0;

  for (const match of body.matchAll(methodPattern)) {
    for (let index = cursor; index < match.index; index += 1) {
      if (body[index] === "{") {
        depth += 1;
      } else if (body[index] === "}") {
        depth -= 1;
      }
    }
    if (depth === 0) {
      methods.push(match[1]);
    }
    cursor = match.index;
  }

  return methods;
}

function testSymbols() {
  const symbols = new Set();
  const testCases = new Set();
  const parsedFiles = walkSwiftFiles("Tests").map((testFile) => {
    const source = fs.readFileSync(path.join(repoRoot, testFile), "utf8");
    return swiftCodeWithoutCommentsAndStrings(source);
  });

  for (const code of parsedFiles) {
    const classPattern = /\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:[^{]*\bXCTestCase\b[^{]*\{/g;
    for (const match of code.matchAll(classPattern)) {
      const testCase = match[1];
      const openingBrace = match.index + match[0].lastIndexOf("{");
      const closingBrace = closingBraceIndex(code, openingBrace);
      if (closingBrace === undefined) {
        continue;
      }
      testCases.add(testCase);
      for (const method of directTestMethods(code, openingBrace, closingBrace)) {
        symbols.add(`${testCase}.${method}`);
      }
    }
  }

  for (const code of parsedFiles) {
    const extensionPattern = /\bextension\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*:[^{]+)?\s*\{/g;
    for (const match of code.matchAll(extensionPattern)) {
      const testCase = match[1];
      if (!testCases.has(testCase)) {
        continue;
      }
      const openingBrace = match.index + match[0].lastIndexOf("{");
      const closingBrace = closingBraceIndex(code, openingBrace);
      if (closingBrace === undefined) {
        continue;
      }
      for (const method of directTestMethods(code, openingBrace, closingBrace)) {
        symbols.add(`${testCase}.${method}`);
      }
    }
  }

  return symbols;
}

function parseArguments(args) {
  if (args.length === 0) {
    return {};
  }

  let base;
  let head;
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (!value || !["--base", "--head"].includes(flag)) {
      throw new Error("usage: node scripts/check-comment-contracts.mjs [--base <sha> --head <sha>]");
    }
    if (flag === "--base") {
      base = value;
    } else {
      head = value;
    }
  }
  if (!base || !head) {
    throw new Error("--base and --head must be provided together");
  }
  return { base, head };
}

function addedLines(base, head) {
  const swiftPathspecs = swiftScopeRoots.flatMap((root) => [
    `:(glob)${root}/*.swift`,
    `:(glob)${root}/**/*.swift`,
  ]);
  const diff = spawnSync(
    "git",
    [
      "-c",
      "core.quotePath=false",
      "diff",
      "--text",
      "--unified=0",
      "--no-color",
      "--no-ext-diff",
      "--no-renames",
      base,
      head,
      "--",
      "project.yml",
      ...swiftPathspecs,
    ],
    { cwd: repoRoot, encoding: "utf8", maxBuffer: gitOutputMaxBuffer },
  );
  if (diff.status !== 0) {
    throw new Error(`git diff failed: ${diff.error?.message || diff.stderr.trim() || diff.stdout.trim()}`);
  }

  return addedLinesFromUnifiedDiff(diff.stdout)
    .filter(({ file }) => file === "project.yml"
      || swiftScopeRoots.some(
        (root) => file.startsWith(`${root}/`) && file.endsWith(".swift"),
      ))
    .map(({ file, line }) => ({ file, line }));
}

function commentsAtRevision(file, revision) {
  const shown = spawnSync("git", ["show", `${revision}:${file}`], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: gitOutputMaxBuffer,
  });
  if (shown.status !== 0) {
    throw new Error(
      `git show failed for ${file} at ${revision}: ${shown.error?.message || shown.stderr.trim() || shown.stdout.trim()}`,
    );
  }
  return file === "project.yml"
    ? yamlCommentEntries(shown.stdout)
    : swiftCommentEntries(shown.stdout);
}

let range;
try {
  range = parseArguments(process.argv.slice(2));
} catch (error) {
  console.error(`check-comment-contracts: ${error.message}`);
  process.exit(2);
}

const errors = [];
const registryPath = path.join(repoRoot, "docs", "invariants.md");
let registry = "";
try {
  registry = fs.readFileSync(registryPath, "utf8");
} catch (error) {
  errors.push(`docs/invariants.md: cannot read invariant registry: ${error.message}`);
}
const registeredInvariantIDs = new Set(
  [...registry.matchAll(/^###\s+(INV-[A-Z0-9-]+)\b/gm)].map((match) => match[1]),
);
const knownTestSymbols = testSymbols();
const commentsByFile = new Map();

for (const swiftFile of swiftScopeRoots.flatMap(walkSwiftFiles).sort()) {
  const source = fs.readFileSync(path.join(repoRoot, swiftFile), "utf8");
  commentsByFile.set(swiftFile, swiftCommentEntries(source));
}
const projectPath = path.join(repoRoot, "project.yml");
if (fs.existsSync(projectPath)) {
  commentsByFile.set("project.yml", yamlCommentEntries(fs.readFileSync(projectPath, "utf8")));
}

for (const [file, comments] of commentsByFile) {
  for (const comment of comments) {
    for (const match of comment.text.matchAll(/\bINV-[A-Z0-9]+(?:-[A-Z0-9]+)*\b/g)) {
      if (!registeredInvariantIDs.has(match[0])) {
        errors.push(`${file}:${comment.line}: unregistered invariant ID ${match[0]}`);
      }
    }

    let searchFrom = 0;
    while (true) {
      const pinnedIndex = comment.text.indexOf("pinned:", searchFrom);
      if (pinnedIndex === -1) {
        break;
      }
      const remainder = comment.text.slice(pinnedIndex + "pinned:".length).trimStart();
      const symbolMatch = remainder.match(/^([A-Za-z_][A-Za-z0-9_]*)\.(test[A-Za-z0-9_]+)\b/);
      if (!symbolMatch) {
        errors.push(`${file}:${comment.line}: pinned breadcrumb must name an exact TestCase.testMethod symbol`);
      } else {
        const symbol = `${symbolMatch[1]}.${symbolMatch[2]}`;
        if (!knownTestSymbols.has(symbol)) {
          errors.push(`${file}:${comment.line}: pinned test symbol does not exist: ${symbol}`);
        }
      }
      searchFrom = pinnedIndex + "pinned:".length;
    }
  }
}

if (range.base && range.head) {
  let additions;
  try {
    additions = addedLines(range.base, range.head);
  } catch (error) {
    console.error(`check-comment-contracts: ${error.message}`);
    process.exit(2);
  }

  const revisionCommentsByFile = new Map();
  try {
    for (const addition of additions) {
      if (!revisionCommentsByFile.has(addition.file)) {
        revisionCommentsByFile.set(
          addition.file,
          commentsAtRevision(addition.file, range.head),
        );
      }
      const comments = revisionCommentsByFile.get(addition.file);
      for (const comment of comments.filter((entry) => entry.line === addition.line)) {
        for (const marker of deferredMarkers) {
          if (new RegExp(`\\b${marker}\\b`).test(comment.text)) {
            errors.push(`${addition.file}:${addition.line}: new deferred-work marker ${marker}`);
          }
        }
        if (/\bP[0-3]\s+r\d+\b/i.test(comment.text)) {
          errors.push(`${addition.file}:${addition.line}: new review-round shorthand; cite a durable PR, plan, or invariant`);
        }
      }
    }
  } catch (error) {
    console.error(`check-comment-contracts: ${error.message}`);
    process.exit(2);
  }
}

if (errors.length > 0) {
  for (const error of [...new Set(errors)]) {
    console.error(`check-comment-contracts: ${error}`);
  }
  process.exitCode = 1;
} else {
  console.log("check-comment-contracts: invariant and pinned-test comments are valid");
}
