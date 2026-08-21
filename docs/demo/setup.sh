#!/usr/bin/env bash
# Build the throwaway farm the demo tapes record against.
#
# Everything here is fictional: a made-up storefront, a made-up tracker at
# tracker.example.com, and a git checkout with no history worth keeping. The
# tapes need a real farm because herdr-ingest cuts real worktrees, and a dry run
# still resolves the main checkout to name them.
#
# Idempotent: it deletes and rebuilds, so a re-record starts from the same state
# and the GIFs stay diffable.
set -euo pipefail

FARM="${1:-/tmp/herdr-ingest-demo/farm}"
MAIN="$FARM/main"

rm -rf "${FARM%/*}"
mkdir -p "$MAIN"

# A source tree the fixture items can point at. The paths match the `subtitle`
# of each item in queue.json, so a brief names a file that exists.
mkdir -p "$MAIN"/{services/checkout,gateway/rpc,webhooks,billing/invoice,notifications/templates}

cat > "$MAIN/services/checkout/total.rb" <<'RUBY'
module Checkout
  # FIXME: the accumulator is seeded from the pre-discount subtotal, so the last
  # line item is charged at full price. Fold the discount in before summing.
  def self.apply_discounts(lines, coupon)
    subtotal = lines.sum(&:amount)
    lines.each { |line| subtotal -= line.amount * coupon.rate }
    subtotal
  end
end
RUBY

cat > "$MAIN/gateway/session.go" <<'GO'
package gateway

// TODO: set SameSite=Lax here; the embedded widget should get its own cookie
// rather than weakening the default for every session.
func issueCookie(w http.ResponseWriter, id string) {
	http.SetCookie(w, &http.Cookie{
		Name:     "sid",
		Value:    id,
		Secure:   true,
		HttpOnly: true,
	})
}
GO

cat > "$MAIN/gateway/rpc/client.go" <<'GO'
package rpc

// TODO: give each downstream its own retry budget, keyed by service name.
var retryBudget = newBudget(100)

func newClient(name string) *Client {
	return &Client{name: name, budget: retryBudget}
}
GO

cat > "$MAIN/webhooks/verify.py" <<'PY'
import hashlib


def check_signature(payload: bytes, secret: bytes, given: str) -> bool:
    # FIXME: `==` short-circuits on the first differing byte. Use
    # hmac.compare_digest so the comparison takes constant time.
    expected = hashlib.sha256(secret + payload).hexdigest()
    return expected == given
PY

cat > "$MAIN/billing/invoice/render.ts" <<'TS'
const SYMBOL: Record<string, string> = { "en-US": "$", "de-DE": "\u20ac" };

// TODO: replace this table with Intl.NumberFormat; de-DE puts the symbol last.
export function formatMoney(cents: number, locale: string): string {
  return `${SYMBOL[locale] ?? "$"}${(cents / 100).toFixed(2)}`;
}
TS

printf 'Subject: Welcome to you new account\n\nThanks for signing up.\n' \
  > "$MAIN/notifications/templates/welcome.txt"

git -C "$MAIN" init -q -b main
git -C "$MAIN" -c user.name=demo -c user.email=demo@example.com \
  commit -q --allow-empty --no-gpg-sign -m "acme storefront" --quiet 2>/dev/null || true
git -C "$MAIN" add -A
git -C "$MAIN" -c user.name=demo -c user.email=demo@example.com \
  commit -q --no-gpg-sign -m "acme storefront"

printf '%s\n' "$FARM"
