/**
 * Runs macOS ad-hoc re-sign after `tauri build` (see src-tauri/macos-resign-bundle.sh).
 * No-op on non-macOS so `npm run tauri:build` works on Windows/Linux without bash.
 */
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

if (process.platform !== 'darwin') {
  process.exit(0);
}

const script = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  'src-tauri',
  'macos-resign-bundle.sh',
);
execFileSync('bash', [script], { stdio: 'inherit' });
