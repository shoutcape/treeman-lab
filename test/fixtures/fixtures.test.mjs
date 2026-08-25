import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const fixtures = join(dirname(fileURLToPath(import.meta.url)));

describe("TreeMan lab fixtures", () => {
  it("includes files that exercise common worktree paths", () => {
    expect(existsSync(join(fixtures, ".hidden-fixture"))).toBe(true);
    expect(existsSync(join(fixtures, "nested", "config", "settings.json"))).toBe(true);
    expect(existsSync(join(fixtures, "with spaces", "filename.txt"))).toBe(true);
  });

  it("keeps fixture content deterministic", () => {
    const settings = JSON.parse(
      readFileSync(join(fixtures, "nested", "config", "settings.json"), "utf8"),
    );

    expect(settings).toEqual({
      name: "treeman-lab-fixture",
      enabled: true,
      values: [1, 2, 3],
    });
  });

  it("provides branch names with common slug characters", () => {
    const branchNames = JSON.parse(
      readFileSync(join(fixtures, "branch-names.json"), "utf8"),
    );

    expect(branchNames).toEqual([
      "feature/slash-case",
      "fix.with.dots",
      "topic_with_underscores",
      "release-2026-08",
    ]);
  });

  it("includes an executable fixture", () => {
    expect(statSync(join(fixtures, "executable-fixture.sh")).mode & 0o111).not.toBe(0);
  });
});
