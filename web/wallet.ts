import { getWallets } from "@wallet-standard/app";
import type { Wallet, WalletAccount } from "@wallet-standard/base";
import type { StandardConnectFeature } from "@wallet-standard/features";
import type { SolanaSignAndSendTransactionFeature } from "@solana/wallet-standard-features";
const element = <T extends HTMLElement>(id: string) =>
  document.getElementById(id) as T;
const input = (id: string) => element<HTMLInputElement>(id);
const button = (id: string) => element<HTMLButtonElement>(id);
const text = (id: string, value: string) => {
  element(id).textContent = value;
};
const random = () =>
  Array.from(crypto.getRandomValues(new Uint8Array(32)), (x) =>
    x.toString(16).padStart(2, "0"),
  ).join("");
const units = (s: string) => {
  if (!/^(0|[1-9][0-9]{0,10})(\.[0-9]{1,8})?$/.test(s))
    throw Error("Use a decimal amount with at most 8 places.");
  const [w, f = ""] = s.split(".");
  return BigInt(w) * 100000000n + BigInt(f.padEnd(8, "0"));
};
const coins = (n: bigint) =>
  `${n / 100000000n}.${(n % 100000000n).toString().padStart(8, "0")}`;
let wallets: readonly Wallet[] = [];
let wallet: Wallet | undefined;
let account: WalletAccount | undefined;
let profile = "";
let enabled = false;
type OrderInput = {
  direction: string;
  input: string;
  recipient: string;
  refund: string;
  sourceOwner: string | null;
  idempotencyKey: string;
};
type Session = {
  capability: string;
  id: string | null;
  request: OrderInput | null;
};
let session: Session | undefined;
const storageKey = "ecx-bridge-order-v1";
try {
  const saved = localStorage.getItem(storageKey);
  if (saved) session = JSON.parse(saved) as Session;
} catch {
  localStorage.removeItem(storageKey);
}
const fragment = new URLSearchParams(location.hash.slice(1));
if (fragment.get("order") && fragment.get("cap")) {
  session = {
    id: fragment.get("order"),
    capability: fragment.get("cap")!,
    request: null,
  };
  history.replaceState(null, "", location.pathname);
}
function persist() {
  if (session) localStorage.setItem(storageKey, JSON.stringify(session));
}
async function api(path: string, method = "GET", body?: unknown) {
  const response = await fetch(path, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(session ? { Authorization: `Bearer ${session.capability}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    cache: "no-store",
    referrerPolicy: "no-referrer",
  });
  const value = await response.json();
  if (!response.ok)
    throw Error(value.error || value.reason || "Request unavailable");
  return value;
}
function attempt(action: () => Promise<void>) {
  return async () => {
    text("error", "");
    try {
      await action();
    } catch (e) {
      text("error", e instanceof Error ? e.message : "Operation failed");
    }
  };
}
function discover() {
  wallets = getWallets()
    .get()
    .filter(
      (w) =>
        "standard:connect" in w.features &&
        "solana:signAndSendTransaction" in w.features,
    );
  const select = element<HTMLSelectElement>("wallets");
  select.replaceChildren(new Option("Choose a detected wallet", ""));
  wallets.forEach((w, i) => select.add(new Option(w.name, String(i))));
}
getWallets().on("register", discover);
getWallets().on("unregister", discover);
discover();
button("connect").onclick = attempt(async () => {
  const index = element<HTMLSelectElement>("wallets").value;
  if (index === "") throw Error("Choose an installed Solana wallet.");
  wallet = wallets[Number(index)];
  if (!wallet) throw Error("Wallet unavailable");
  const feature = wallet.features[
    "standard:connect"
  ] as StandardConnectFeature["standard:connect"];
  const result = await feature.connect();
  const chain =
    profile === "CanonicalBeta" ? "solana:mainnet" : "solana:devnet";
  account = result.accounts.find((a) => a.chains.includes(chain));
  if (!account) throw Error(`Wallet must support ${chain}`);
  text("account", account.address);
  if (input("direction").value === "NativeToWrapped")
    input("recipient").value = account.address;
});
function preview() {
  try {
    const a = units(input("amount").value);
    const rate = input("direction").value === "NativeToWrapped" ? 20n : 100n;
    const f = (a * rate + 9999n) / 10000n;
    text("fee", coins(f));
    text("net", coins(a - f));
  } catch {
    text("fee", "—");
    text("net", "—");
  }
}
input("amount").oninput = preview;
input("direction").onchange = () => {
  const wrap = input("direction").value === "NativeToWrapped";
  element("refund-field").hidden = !wrap;
  element("refund-note").hidden = wrap;
  input("refund").required = wrap;
  input("refund").disabled = !wrap;
  input("recipient").value = wrap && account ? account.address : "";
  preview();
};
async function refresh() {
  if (!session?.id) return;
  const o = await api(`/api/v1/orders/${encodeURIComponent(session.id)}`);
  text("status", o.status);
  text("details", JSON.stringify(o, null, 2));
  button("refresh").disabled = false;
  button("copy").disabled = false;
  button("sign").disabled =
    !enabled || o.request.direction !== "WrappedToNative" || !account;
}
element<HTMLFormElement>("order-form").onsubmit = (e) => {
  e.preventDefault();
  void attempt(async () => {
    if (!enabled) throw Error("Deposits are currently disabled.");
    if (!session) {
      const direction = input("direction").value;
      if (direction === "WrappedToNative" && !account)
        throw Error("Connect the source wallet first.");
      session = {
        capability: random(),
        id: null,
        request: {
          direction,
          input: units(input("amount").value).toString(),
          recipient: input("recipient").value.trim(),
          refund:
            direction === "WrappedToNative"
              ? account!.address
              : input("refund").value.trim(),
          sourceOwner:
            direction === "WrappedToNative" ? account!.address : null,
          idempotencyKey: random(),
        },
      };
      persist();
    }
    if (!session.request) throw Error("Recovered order: use Refresh.");
    const o = await api("/api/v1/orders", "POST", session.request);
    session.id = o.orderId;
    persist();
    await refresh();
  })();
};
button("refresh").onclick = attempt(refresh);
button("new").onclick = () => {
  session = undefined;
  localStorage.removeItem(storageKey);
  text("status", "No order yet.");
  text("details", "");
  for (const id of ["refresh", "copy", "sign"]) button(id).disabled = true;
};
button("copy").onclick = attempt(async () => {
  if (!session?.id) return;
  await navigator.clipboard.writeText(
    `${location.origin}/#order=${encodeURIComponent(session.id)}&cap=${session.capability}`,
  );
  text("status", "Recovery link copied. Keep it private.");
});
button("sign").onclick = attempt(async () => {
  if (!wallet || !account || !session?.id)
    throw Error("Connect the bound source wallet.");
  const prepared = await api(
    `/api/v1/orders/${encodeURIComponent(session.id)}/transaction`,
    "POST",
  );
  const bytes = Uint8Array.from(atob(prepared.transaction), (c) =>
    c.charCodeAt(0),
  );
  const feature = wallet.features[
    "solana:signAndSendTransaction"
  ] as SolanaSignAndSendTransactionFeature["solana:signAndSendTransaction"];
  await feature.signAndSendTransaction({
    account,
    chain: profile === "CanonicalBeta" ? "solana:mainnet" : "solana:devnet",
    transaction: bytes,
  });
  text(
    "status",
    "Submitted by wallet; waiting for independent chain verification.",
  );
  await refresh();
});
void attempt(async () => {
  const c = await api("/api/v1/config");
  profile = c.profile;
  enabled = c.availability.available && c.implementationReady;
  text(
    "network",
    c.profile === "L2LSignetDevnet"
      ? "L2L public Signet ↔ Solana Devnet"
      : c.profile === "CanonicalBeta"
        ? "ECX betanet ↔ Solana mainnet-beta"
        : "ECX betanet ↔ Solana Devnet",
  );
  text(
    "availability",
    enabled
      ? "Ready for transfers"
      : "The bridge is paused for testing. No deposits are accepted.",
  );
  button("create").disabled = !enabled;
  button("create").textContent = enabled
    ? "Create immutable order"
    : "Deposits unavailable";
  if (session?.id) {
    persist();
    await refresh();
  }
})();
