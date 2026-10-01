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
let busy = false;
let minimum = 0n;
let maximum = 0n;
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
  submitted?: boolean;
};
type Order = {
  orderId: string; request: OrderInput; quote: { gross: string; net: string; fee: string };
  status: string; deadline: number; depositInstruction: string | null; payoutTx: string | null;
};
let session: Session | undefined;
let order: Order | undefined;
let history: Session[] = [];
const storageKey = "ecx-bridge-order-v1";
try {
  const saved = localStorage.getItem(storageKey);
  if (saved) session = JSON.parse(saved) as Session;
  history = JSON.parse(localStorage.getItem(`${storageKey}-history`) || "[]") as Session[];
  if (!Array.isArray(history)) history = [];
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
  window.history.replaceState(null, "", location.pathname);
}
function persist() {
  if (session) {
    localStorage.setItem(storageKey, JSON.stringify(session));
    if (session.id) history = [session, ...history.filter(s => s.id !== session!.id)].slice(0, 20);
  } else localStorage.removeItem(storageKey);
  localStorage.setItem(`${storageKey}-history`, JSON.stringify(history));
  const select = element<HTMLSelectElement>("history");
  select.replaceChildren(new Option("Choose a saved order", ""));
  history.filter(s => s.id).forEach(s => select.add(new Option(s.id!.slice(0, 12), s.id!)));
  select.value = session?.id || "";
  element("history-field").hidden = history.length === 0;
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
  if (!response.ok) {
    const messages: Record<string, string> = {
      custody_not_reconciled: "The bridge is checking its balances. Wait a moment, then retry this order.",
      scanners_not_fresh: "The bridge is catching up with the networks. Wait a moment, then retry this order.",
      insufficient_fee_budget: "The operator’s network-fee allowance is reserved by another transfer. Wait for it to finish, then retry.",
      rpc_transport_unknown_outcome: "A network request was interrupted. Retry to recover the same order.",
      rpc_rate_limited: "The network provider is busy. Wait a moment, then retry the same order.",
      deposit_window_closed: "This order’s deposit window has closed. Refresh its status before creating a new order.",
      intake_paused: "New transfers are paused. Existing orders remain saved.",
      insufficient_source_tokens: "The connected wallet does not have enough of this deployment’s Devnet token.",
      insufficient_deposit_fee_sol: "The connected wallet needs Devnet SOL for the deposit network fee.",
    };
    throw Error(messages[value.error] || value.error || value.reason || "Request unavailable");
  }
  return value;
}
function attempt(action: () => Promise<void>, clearError = true) {
  return async () => {
    if (busy) return;
    busy = true;
    controls();
    if (clearError) text("error", "");
    try {
      await action();
    } catch (e) {
      text("error", e instanceof Error ? e.message : "Operation failed");
    } finally {
      busy = false;
      controls();
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
  if (input("direction").value === "NativeToWrapped" && !session?.request && !session?.id)
    input("recipient").value = account.address;
});
function controls() {
  button("create").disabled = busy || !enabled || Boolean(session?.id);
  button("create").textContent = session?.id ? "Order created" : !enabled ? "Deposits unavailable"
    : session?.request ? "Retry saved order" : "Create order";
  for (const id of ["direction", "amount", "recipient", "refund"])
    input(id).disabled = busy || Boolean(session?.request || session?.id)
      || (id === "refund" && input("direction").value === "WrappedToNative");
  button("connect").disabled = busy;
  button("new").disabled = busy;
  for (const id of ["refresh", "copy"]) button(id).disabled = busy || !session?.id;
  button("sign").disabled = busy || !enabled || !account || order?.request.direction !== "WrappedToNative"
    || account.address !== order.request.sourceOwner || order.status !== "AwaitingDeposit"
    || Date.now() >= order.deadline * 1000 || Boolean(session?.submitted);
  button("sign").textContent = session?.submitted ? "Deposit sent" : "Sign deposit";
}
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
function showRequest(request: OrderInput) {
  input("direction").value = request.direction;
  input("amount").value = coins(BigInt(request.input));
  input("recipient").value = request.recipient;
  input("refund").value = request.refund;
  const wrap = request.direction === "NativeToWrapped";
  element("refund-field").hidden = !wrap;
  element("refund-note").hidden = wrap;
  input("refund").required = wrap;
  preview();
}
async function refresh() {
  if (!session?.id) return;
  const id = session.id;
  const o: Order = await api(`/api/v1/orders/${encodeURIComponent(id)}`);
  if (session?.id !== id) return;
  order = o;
  showRequest(o.request);
  const statuses: Record<string, string> = {
    Provisioning: "Preparing your deposit instructions…",
    AwaitingDeposit: "Waiting for your deposit and its network confirmations.",
    Ready: "Deposit verified. Your payout is queued.", Preparing: "Preparing your payout.",
    Paying: "Your payout is being sent and confirmed.", Paid: "Transfer complete.",
    Refunding: "Your refund is being processed.", Refunded: "Your deposit was refunded.",
    ExpiredUnfunded: "The deposit window expired. Create a new order to try again.",
    NeedsReview: "This transfer needs operator review. Do not send another deposit.",
  };
  const wrap = o.request.direction === "NativeToWrapped";
  const awaiting = o.status === "AwaitingDeposit" && Date.now() < o.deadline * 1000;
  element("order-details").hidden = false;
  text("order-short", `Order ${id.slice(0, 12)}`);
  text("status", session.submitted && o.status === "AwaitingDeposit"
    ? "Deposit submitted. Waiting for independent network verification." : statuses[o.status] || o.status);
  text("order-send", `${coins(BigInt(o.quote.gross))} ${wrap ? "Signet coins" : "Devnet tokens"}`);
  text("order-receive", `${coins(BigInt(o.quote.net))} ${wrap ? "Devnet tokens" : "Signet coins"}`);
  text("order-fee", coins(BigInt(o.quote.fee)));
  text("order-destination", o.request.recipient);
  element("native-instructions").hidden = !wrap || !awaiting || !o.depositInstruction || !enabled;
  element("solana-instructions").hidden = wrap || !awaiting || Boolean(session.submitted) || !enabled;
  text("deposit-amount", coins(BigInt(o.quote.gross)));
  text("deposit-address", o.depositInstruction || "");
  text("deposit-deadline", o.status === "AwaitingDeposit" ? awaiting
    ? `Deposit before ${new Date(o.deadline * 1000).toLocaleTimeString()}. Late or incorrect amounts need operator review.`
    : "The deposit window has closed. Waiting for the bridge to finish checking the network." : "");
  const link = element<HTMLAnchorElement>("payout-link");
  link.hidden = !o.payoutTx;
  if (o.payoutTx) {
    const nativePayout = o.status === "Refunded" ? wrap : !wrap;
    link.href = nativePayout ? `https://explorer.signet.drivechain.info/tx/${encodeURIComponent(o.payoutTx)}`
      : `https://explorer.solana.com/tx/${encodeURIComponent(o.payoutTx)}?cluster=devnet`;
  }
}
element<HTMLFormElement>("order-form").onsubmit = (e) => {
  e.preventDefault();
  void attempt(async () => {
    if (!enabled) throw Error("Deposits are currently disabled.");
    if (!session) {
      const direction = input("direction").value;
      const quantity = units(input("amount").value);
      if (quantity < minimum || quantity > maximum) throw Error("Enter an amount within the displayed transfer limits.");
      if (direction === "WrappedToNative" && !account)
        throw Error("Connect the source wallet first.");
      session = {
        capability: random(),
        id: null,
        request: {
          direction,
          input: quantity.toString(),
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
  if (busy) return;
  persist();
  session = undefined;
  order = undefined;
  persist();
  text("status", "No order yet.");
  text("order-short", "");
  element("order-details").hidden = true;
  controls();
};
element<HTMLSelectElement>("history").onchange = () => { void attempt(async () => {
  const saved = history.find(s => s.id === element<HTMLSelectElement>("history").value);
  if (saved) { session = saved; persist(); await refresh(); }
})(); };
button("copy-address").onclick = attempt(async () => {
  if (order?.depositInstruction) {
    await navigator.clipboard.writeText(order.depositInstruction);
    text("message", "Deposit address copied.");
  }
});
button("copy-mint").onclick = attempt(async () => {
  await navigator.clipboard.writeText(element("mint").textContent || "");
  text("message", "Devnet token mint copied.");
});
button("copy").onclick = attempt(async () => {
  if (!session?.id) return;
  await navigator.clipboard.writeText(
    `${location.origin}/#order=${encodeURIComponent(session.id)}&cap=${session.capability}`,
  );
  text("message", "Recovery link copied. Keep it private.");
});
button("sign").onclick = attempt(async () => {
  if (!wallet || !account || !session?.id || account.address !== order?.request.sourceOwner)
    throw Error("Connect the bound source wallet.");
  if (session.submitted) throw Error("This deposit has already been submitted.");
  const prepared = await api(
    `/api/v1/orders/${encodeURIComponent(session.id)}/transaction`,
    "POST",
  );
  const bytes = Uint8Array.from(atob(prepared.transaction), (c) =>
    c.charCodeAt(0),
  );
  if (prepared.owner !== account.address || prepared.orderId !== session.id || prepared.chain !== "solana:devnet")
    throw Error("The deposit does not match the connected wallet and order.");
  const feature = wallet.features[
    "solana:signAndSendTransaction"
  ] as SolanaSignAndSendTransactionFeature["solana:signAndSendTransaction"];
  await feature.signAndSendTransaction({
    account,
    chain: profile === "CanonicalBeta" ? "solana:mainnet" : "solana:devnet",
    transaction: bytes,
  });
  session.submitted = true;
  persist();
  text(
    "status",
    "Submitted by wallet; waiting for independent chain verification.",
  );
  await refresh();
});
async function refreshConfiguration() {
  const c = await api("/api/v1/config");
  profile = c.profile;
  text("mint", c.mint);
  enabled = c.profile === "L2LSignetDevnet" && c.availability.available && c.intakeEnabled;
  minimum = BigInt(c.minInput); maximum = BigInt(c.maxInput);
  text("limits", `Transfer ${coins(minimum)}–${coins(maximum)} coins or tokens.`);
  if (!input("amount").value) { input("amount").value = coins(minimum); preview(); }
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
      ? "Ready for test transfers"
      : `Deposits paused · ${String(c.availability.reason).replaceAll("_", " ")}`,
  );
}
if (session?.request) showRequest(session.request);
persist(); controls();
async function poll() {
  await attempt(async () => { await refreshConfiguration(); await refresh(); }, false)();
  window.setTimeout(() => { void poll(); }, 10000);
}
void poll();
