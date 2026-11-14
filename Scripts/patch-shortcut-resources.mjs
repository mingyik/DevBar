// KeyboardShortcuts 1.10.0: look inside a macOS app's Resources before the
// generated SwiftPM accessor falls back to an absolute build-machine path.
import { readFileSync, writeFileSync, chmodSync, statSync } from 'node:fs';
const file = new URL('../.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Utilities.swift', import.meta.url);
const original = 'NSLocalizedString(self, bundle: .module, comment: self)';
const patched = 'NSLocalizedString(self, bundle: Bundle.main.url(forResource: "KeyboardShortcuts_KeyboardShortcuts", withExtension: "bundle").flatMap { Bundle(url: $0) } ?? .module, comment: self)';
const source = readFileSync(file, 'utf8');
if (!source.includes(patched)) {
  if (!source.includes(original)) throw new Error('KeyboardShortcuts resource lookup changed; review the compatibility patch');
  chmodSync(file, statSync(file).mode | 0o200);
  writeFileSync(file, source.replace(original, patched));
}
