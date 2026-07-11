import assert from "node:assert/strict";
import test from "node:test";
import { addedLinesFromUnifiedDiff } from "../unified-diff.mjs";

test("keeps header-looking additions attributed to the active hunk", () => {
  const patch = `diff --git a/project.yml b/project.yml
--- a/project.yml
+++ b/project.yml
@@ -10,0 +10,2 @@
+++ b/LavaSecApp/Decoy.swift
+  OTHER_SWIFT_FLAGS: -D LAVA_QA_TOOLS
`;

  assert.deepEqual(addedLinesFromUnifiedDiff(patch), [
    {
      file: "project.yml",
      line: 10,
      content: "++ b/LavaSecApp/Decoy.swift",
    },
    {
      file: "project.yml",
      line: 11,
      content: "  OTHER_SWIFT_FLAGS: -D LAVA_QA_TOOLS",
    },
  ]);
});

test("rejects Git C-quoted destination paths instead of silently mis-scoping them", () => {
  const patch = `diff --git "a/Sources/Foo\\tBar.swift" "b/Sources/Foo\\tBar.swift"
new file mode 100644
--- /dev/null
+++ "b/Sources/Foo\\tBar.swift"
@@ -0,0 +1 @@
+// FIXME: must remain attributable
`;

  assert.throws(
    () => addedLinesFromUnifiedDiff(patch),
    /unsupported destination path header/,
  );
});

test("rejects hunk body lines beyond the declared counts", () => {
  const patch = `diff --git a/file.txt b/file.txt
new file mode 100644
--- /dev/null
+++ b/file.txt
@@ -0,0 +1 @@
+first
+surplus
`;

  assert.throws(
    () => addedLinesFromUnifiedDiff(patch),
    /hunk body appears outside a declared hunk/,
  );
});
