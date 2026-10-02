// Compare arguments by position and ABI type, allowing translated word order.
// A mismatched native format can corrupt a displayed value or crash String(format:).
export function formatSignature(value) {
  const argumentsByPosition = [];
  let next = 1;
  let escapedPercents = 0;
  for (const match of value.matchAll(/%%|%(?:(\d+)\$)?[-+#0 ]*(?:\d+)?(?:\.\d+)?(hh|h|ll|l|z|j|t|L)?([@diuoxXfFeEgGaAcCsSp])/g)) {
    if (match[0] === "%%") { escapedPercents += 1; continue; }
    argumentsByPosition.push(`${match[1] ?? next++}:${match[2] ?? ""}${match[3]}`);
  }
  return JSON.stringify({
    arguments: argumentsByPosition.sort(),
    escapedPercents,
    parameters: [...value.matchAll(/\$\{(\w+)\}/g)].map(match => match[1]).sort()
  });
}
