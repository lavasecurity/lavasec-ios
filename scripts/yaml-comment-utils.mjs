function startsQuotedScalar(line, quoteIndex) {
  let previousIndex = quoteIndex - 1;
  while (previousIndex >= 0 && /\s/.test(line[previousIndex])) {
    previousIndex -= 1;
  }
  if (previousIndex < 0) {
    return true;
  }
  if (line[previousIndex] === "-") {
    const firstContentIndex = line.search(/\S/);
    return previousIndex === firstContentIndex && previousIndex < quoteIndex - 1;
  }
  return ":,?[{".includes(line[previousIndex]);
}

// Splits a complete YAML document into content/comment pairs while retaining
// quote state across physical lines. A quote opens only at a scalar boundary,
// so apostrophes embedded in plain scalars do not hide subsequent comments.
export function splitYAMLDocumentComments(source) {
  if (source.includes("\uFEFF")) {
    throw new Error("unsupported YAML byte-order mark");
  }
  if (/\r(?!\n)|[\u0085\u2028\u2029]/u.test(source)) {
    throw new Error("unsupported YAML line separator");
  }
  let quote;

  return source.split(/\r?\n/).map((line) => {
    for (let index = 0; index < line.length; index += 1) {
      const character = line[index];

      if (quote === "double") {
        if (character === "\\") {
          index += 1;
        } else if (character === '"') {
          quote = undefined;
        }
        continue;
      }

      if (quote === "single") {
        if (character === "'" && line[index + 1] === "'") {
          index += 1;
        } else if (character === "'") {
          quote = undefined;
        }
        continue;
      }

      if (character === '"' && startsQuotedScalar(line, index)) {
        quote = "double";
      } else if (character === "'" && startsQuotedScalar(line, index)) {
        quote = "single";
      } else if (character === "#" && (index === 0 || /\s/.test(line[index - 1]))) {
        return {
          content: line.slice(0, index).trimEnd(),
          comment: line.slice(index + 1),
        };
      }
    }

    return { content: line, comment: undefined };
  });
}
