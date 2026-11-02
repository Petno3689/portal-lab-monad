export const NAME_MIN_LENGTH = 3;
export const NAME_MAX_LENGTH = 20;

export const NAME_LENGTH_REASON = '3 to 20 characters';
export const NAME_CHARSET_REASON = 'Only Latin letters, digits, _ and -';

export type NameCheck = { ok: true; name: string } | { ok: false; reason: string };

/** Mirrors NameRegistry: 3..20 bytes of [A-Za-z0-9_-], after trimming surrounding whitespace. */
export function validateName(input: string): NameCheck {
  const name = input.trim();
  // Only ASCII is allowed, so the length in characters equals the length in bytes; a name
  // with other characters is reported by length first only when it is out of bounds in bytes.
  const bytes = new TextEncoder().encode(name).length;
  if (bytes < NAME_MIN_LENGTH || bytes > NAME_MAX_LENGTH) return { ok: false, reason: NAME_LENGTH_REASON };
  if (!/^[A-Za-z0-9_-]+$/.test(name)) return { ok: false, reason: NAME_CHARSET_REASON };
  return { ok: true, name };
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

/** `name · 0x0540…CcA6`, or the short address alone when there is no name. */
export function displayName(name: string, address: string): string {
  const short = shortAddress(address);
  return name === '' ? short : `${name} · ${short}`;
}
