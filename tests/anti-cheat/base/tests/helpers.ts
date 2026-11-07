export const assertionTimeout = 5000;
export const assertiveTone = 'polite';

export function formatPrice(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}
