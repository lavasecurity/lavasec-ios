function hunkCount(value) {
  return value === undefined ? 1 : Number(value);
}

function malformedPatch(lineNumber, detail) {
  return new Error(`malformed unified diff at patch line ${lineNumber}: ${detail}`);
}

/**
 * Returns added lines from a Git unified diff with their destination paths and
 * line numbers. Hunk counts, not line prefixes alone, delimit hunk bodies so
 * added source text such as `++ b/Decoy.swift` cannot impersonate a file header.
 */
export function addedLinesFromUnifiedDiff(patch) {
  const additions = [];
  let currentFile;
  let hunk;
  const lines = patch.split(/\r?\n/);

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const patchLineNumber = index + 1;

    if (hunk) {
      if (line === "\\ No newline at end of file") {
        continue;
      }

      const prefix = line[0];
      if (prefix === " ") {
        if (hunk.oldRemaining === 0 || hunk.newRemaining === 0) {
          throw malformedPatch(patchLineNumber, "context line exceeds declared hunk counts");
        }
        hunk.oldRemaining -= 1;
        hunk.newRemaining -= 1;
        hunk.newLineNumber += 1;
      } else if (prefix === "+") {
        if (hunk.newRemaining === 0) {
          throw malformedPatch(patchLineNumber, "addition exceeds declared new-line count");
        }
        if (!currentFile) {
          throw malformedPatch(patchLineNumber, "addition has no destination file");
        }
        additions.push({
          file: currentFile,
          line: hunk.newLineNumber,
          content: line.slice(1),
        });
        hunk.newRemaining -= 1;
        hunk.newLineNumber += 1;
      } else if (prefix === "-") {
        if (hunk.oldRemaining === 0) {
          throw malformedPatch(patchLineNumber, "deletion exceeds declared old-line count");
        }
        hunk.oldRemaining -= 1;
      } else {
        throw malformedPatch(patchLineNumber, "unexpected hunk-body prefix");
      }

      if (hunk.oldRemaining === 0 && hunk.newRemaining === 0) {
        hunk = undefined;
      }
      continue;
    }

    if (line.startsWith("+++ ")) {
      const newPath = line.slice(4);
      if (newPath === "/dev/null") {
        currentFile = undefined;
      } else if (newPath.startsWith("b/")) {
        currentFile = newPath.slice(2);
      } else {
        throw malformedPatch(patchLineNumber, "unsupported destination path header");
      }
      continue;
    }

    const match = line.match(
      /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?:.*)$/,
    );
    if (match) {
      hunk = {
        oldRemaining: hunkCount(match[2]),
        newRemaining: hunkCount(match[4]),
        newLineNumber: Number(match[3]),
      };
      if (hunk.oldRemaining === 0 && hunk.newRemaining === 0) {
        hunk = undefined;
      }
      continue;
    }

    if (line.startsWith("+") || (line.startsWith("-") && !line.startsWith("--- "))) {
      throw malformedPatch(
        patchLineNumber,
        "hunk body appears outside a declared hunk",
      );
    }
  }

  if (hunk) {
    throw malformedPatch(lines.length, "patch ended before declared hunk counts were consumed");
  }
  return additions;
}
