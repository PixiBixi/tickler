import { execSync } from "node:child_process";

// Latest release tag at build time; the deploy workflow also runs on every v* tag so this never goes stale.
export function latestVersion(): string {
  try {
    return execSync("git describe --tags --abbrev=0 --match 'v*'", { encoding: "utf8" }).trim();
  } catch {
    return "";
  }
}
