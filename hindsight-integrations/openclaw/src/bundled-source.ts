import { existsSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

/**
 * When the plugin is published with bundled Python source (the fork-release
 * publish flow), hindsight-embed/ sits as a sibling of dist/. Returns its
 * absolute path if present, otherwise undefined so the plugin falls back to
 * the configured embedVersion + uvx behavior.
 */
export function detectBundledPythonRoot(): string | undefined {
  try {
    const here = dirname(fileURLToPath(import.meta.url));
    const candidate = join(here, "..", "hindsight-embed");
    if (existsSync(candidate) && existsSync(join(candidate, "pyproject.toml"))) {
      return candidate;
    }
  } catch {
    // fileURLToPath can throw in non-ESM bundlers; fall through.
  }
  return undefined;
}
