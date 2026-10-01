import QRCode from "qrcode";
type Request = {
  direction: string;
  input: string;
  recipient: string;
  refund: string;
  sourceOwner: null;
  idempotencyKey: string;
};
type Order = {
  orderId: string;
  request: Request;
  quote: { gross: string; fee: string; net: string };
  status: string;
  deadline: number;
  depositInstruction: string | null;
  payoutTx: string | null;
};
type Session = { capability: string; id: string | null; request?: Request };
type Config = {
  profile: string;
  mint: string;
  minInput: string;
  maxInput: string;
  solanaCluster: "devnet" | "mainnet-beta";
  links: { supportUrl: string | null; jupiterUrl: string | null; orcaUrl: string | null; nativeExplorerBase: string | null };
  availability: { available: boolean; reason: string };
};
const el = <T extends HTMLElement = HTMLElement>(id: string): T => {
  const found = document.getElementById(id);
  if (!found) throw Error(`Missing ${id}`);
  return found as T;
};
const input = (id: string) => el<HTMLInputElement>(id),
  button = (id: string) => el<HTMLButtonElement>(id);
const text = (id: string, value: string) => {
  el(id).textContent = value;
};
const random = () =>
  Array.from(crypto.getRandomValues(new Uint8Array(32)), (n) =>
    n.toString(16).padStart(2, "0"),
  ).join("");
const coins = (n: bigint) =>
  `${n / 100000000n}.${(n % 100000000n).toString().padStart(8, "0")}`;
function units(value: string): bigint {
  if (!/^(0|[1-9][0-9]*)(\.[0-9]{1,8})?$/.test(value))
    throw Error("Enter a decimal amount with at most eight places.");
  const [whole, fraction = ""] = value.split(".");
  return BigInt(whole) * 100000000n + BigInt(fraction.padEnd(8, "0"));
}
let session: Session | undefined,
  order: Order | undefined,
  config: Config | undefined,
  busy = false,
  payment = "";
let history: Session[] = [];
try {
  history = JSON.parse(localStorage.getItem("ecx-orders-v2") || "[]");
  session =
    JSON.parse(localStorage.getItem("ecx-current-v2") || "null") || undefined;
} catch {
  history = [];
}
const fragment = new URLSearchParams(location.hash.slice(1));
if (fragment.has("order") && /^[a-f0-9]{64}$/.test(fragment.get("cap") || "")) {
  session = { id: fragment.get("order"), capability: fragment.get("cap")! };
  window.history.replaceState(null, "", location.pathname + location.search);
}
function persist() {
  try {
    if (session)
      localStorage.setItem("ecx-current-v2", JSON.stringify(session));
    else localStorage.removeItem("ecx-current-v2");
    if (session?.id)
      history = [session, ...history.filter((s) => s.id !== session!.id)].slice(
        0,
        20,
      );
    localStorage.setItem("ecx-orders-v2", JSON.stringify(history));
  } catch {
    text(
      "message",
      "Device storage unavailable. Copy your recovery link before leaving.",
    );
  }
  const select = el<HTMLSelectElement>("history");
  select.replaceChildren(
    new Option("Select saved order", ""),
    ...history.map((s) => new Option(s.id!.slice(0, 12), s.id!)),
  );
  select.value = session?.id || "";
  el("history-field").hidden = !history.length;
}
async function api(path: string, method = "GET", body?: unknown): Promise<any> {
  const response = await fetch(path, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(session ? { Authorization: `Bearer ${session.capability}` } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const result = await response.json();
  if (!response.ok)
    throw Error(
      result.error || result.reason || `Request failed (${response.status})`,
    );
  return result;
}
function controls() {
  button("create").disabled =
    busy || !config?.availability.available || Boolean(session?.id);
  button("refresh").disabled = busy || !session?.id;
  button("copy").disabled = busy || !session?.id;
  button("new").disabled = busy;
  for (const id of ["direction", "amount", "recipient", "refund"])
    input(id).disabled = busy || Boolean(session?.request) || Boolean(session?.id);
}
async function attempt(work: () => Promise<void>) {
  if (busy) return;
  busy = true;
  text("error", "");
  controls();
  try {
    await work();
  } catch (error) {
    text(
      "error",
      error instanceof Error
        ? error.message
        : "Request failed. Refresh before sending again.",
    );
  } finally {
    busy = false;
    controls();
  }
}
function direction() {
  const wrap = input("direction").value === "NativeToWrapped";
  el("refund-field").hidden = !wrap;
  input("refund").required = wrap;
  el("refund-note").hidden = wrap;
  text(
    "destination-label",
    wrap ? "Solana destination address" : "Native destination address",
  );
  preview();
}
function showRequest(request: Request) {
  input("direction").value = request.direction;
  input("amount").value = coins(BigInt(request.input));
  input("recipient").value = request.recipient;
  input("refund").value = request.refund;
  direction();
}
function externalLink(id: string, url: string | null | undefined) {
  const link = el<HTMLAnchorElement>(id);
  link.hidden = !url;
  if (url) link.href = url;
  else link.removeAttribute("href");
}
function solanaExplorer(kind: "tx" | "address", value: string) {
  return `https://explorer.solana.com/${kind}/${encodeURIComponent(value)}${config?.solanaCluster === "mainnet-beta" ? "" : "?cluster=devnet"}`;
}
function preview() {
  try {
    const n = units(input("amount").value),
      fee = (n + 99n) / 100n;
    text("fee", coins(fee));
    text("net", n > fee ? coins(n - fee) : "—");
  } catch {
    text("fee", "—");
    text("net", "—");
  }
}
async function loadConfig() {
  config = await api("/api/v1/config");
  text(
    "network",
    config!.profile === "L2LSignetDevnet"
      ? "L2L Signet / Solana Devnet"
      : "ECX betanet / Solana",
  );
  text(
    "network-note",
    config!.profile === "L2LSignetDevnet"
      ? "Test coins only. Select Devnet in your Solana Pay wallet; the transfer URI does not select a network."
      : "Verify the configured networks before paying.",
  );
  text("mint", config!.mint);
  externalLink("mint-link", solanaExplorer("address", config!.mint));
  externalLink("support-link", config!.links?.supportUrl);
  externalLink("jupiter-link", config!.links?.jupiterUrl);
  externalLink("orca-link", config!.links?.orcaUrl);
  el("trading").hidden = !config!.links?.jupiterUrl && !config!.links?.orcaUrl;
  text(
    "availability",
    config!.availability.available
      ? "Bridge is accepting orders."
      : `Deposits paused: ${config!.availability.reason}`,
  );
  text(
    "limits",
    `Amount limits: ${coins(BigInt(config!.minInput))}–${coins(BigInt(config!.maxInput))}`,
  );
  controls();
}
const statuses: Record<string, string> = {
  Provisioning: "Preparing instructions.",
  AwaitingDeposit: "Waiting for payment and confirmations.",
  Ready: "Payment verified. Payout queued.",
  Preparing: "Preparing payout.",
  Paying: "Payout is being confirmed.",
  Paid: "Transfer complete.",
  Refunding: "Refund is being processed.",
  Refunded: "Deposit refunded.",
  ExpiredUnfunded: "Order expired. Do not pay.",
  NeedsReview: "Operator review required. Do not send another payment.",
};
async function refresh() {
  if (!session?.id) return;
  order = await api(`/api/v1/orders/${encodeURIComponent(session.id)}`);
  showRequest(order!.request);
  const refunding = order!.status === "Refunded" || order!.status === "Refunding";
  text("fee", refunding ? "0.00000000" : coins(BigInt(order!.quote.fee)));
  text("net", refunding ? "—" : coins(BigInt(order!.quote.net)));
  text("status", statuses[order!.status] || order!.status);
  text("order-short", `Order ${order!.orderId}`);
  text(
    "order-summary",
    refunding
      ? "Refunds return the deposit to its verified refund destination with no bridge fee. The refund transaction shows the actual amount and recipient."
      : `Send ${coins(BigInt(order!.quote.gross))}; receive ${coins(BigInt(order!.quote.net))}. Fee ${coins(BigInt(order!.quote.fee))}. Destination: ${order!.request.recipient}`,
  );
  el("order-details").hidden = false;
  const awaiting =
    order!.status === "AwaitingDeposit" && Date.now() < order!.deadline * 1000;
  payment = "";
  el("payment-link").hidden = true;
  el("qr").hidden = true;
  el("copy-payment").hidden = true;
  text("deposit-address", "");
  text(
    "deposit-deadline",
    awaiting
      ? `Pay before ${new Date(order!.deadline * 1000).toLocaleString()}. Send the exact amount once.`
      : "",
  );
  if (awaiting && order!.depositInstruction && config?.availability.available) {
    if (order!.request.direction === "NativeToWrapped") {
      payment = order!.depositInstruction;
      text("deposit-address", payment);
    } else {
      const instructions = await api(
        `/api/v1/orders/${encodeURIComponent(session.id)}/transaction`,
        "POST",
      );
      payment = instructions.uri;
      const link = el<HTMLAnchorElement>("payment-link");
      link.href = payment;
      link.hidden = false;
      text("deposit-address", payment);
    }
    await QRCode.toCanvas(el<HTMLCanvasElement>("qr"), payment, {
      width: 240,
      margin: 2,
    });
    el("qr").hidden = false;
    el("copy-payment").hidden = false;
  }
  const link = el<HTMLAnchorElement>("payout-link");
  link.textContent = refunding ? "View refund transaction" : "View payout transaction";
  link.hidden = !order!.payoutTx;
  if (order!.payoutTx) {
    const native =
      order!.status === "Refunded"
        ? order!.request.direction === "NativeToWrapped"
        : order!.request.direction === "WrappedToNative";
    const url = native
      ? config?.links?.nativeExplorerBase ? config.links.nativeExplorerBase + encodeURIComponent(order!.payoutTx) : null
      : solanaExplorer("tx", order!.payoutTx);
    externalLink("payout-link", url);
  }
}
el<HTMLFormElement>("order-form").onsubmit = (e) => {
  e.preventDefault();
  void attempt(async () => {
    if (!config?.availability.available) throw Error("Deposits are paused.");
    if (!session?.request) {
      const n = units(input("amount").value);
      if (n < BigInt(config.minInput) || n > BigInt(config.maxInput))
        throw Error("Amount outside displayed limits.");
      session = {
        capability: random(),
        id: null,
        request: {
          direction: input("direction").value,
          input: n.toString(),
          recipient: input("recipient").value.trim(),
          refund:
            input("direction").value === "NativeToWrapped"
              ? input("refund").value.trim()
              : "",
          sourceOwner: null,
          idempotencyKey: random(),
        },
      };
      persist();
    }
    const saved = await api("/api/v1/orders", "POST", session.request);
    session.id = saved.orderId;
    persist();
    await refresh();
  });
};
input("direction").onchange = direction;
input("amount").oninput = preview;
button("refresh").onclick = () =>
  void attempt(async () => {
    await loadConfig();
    await refresh();
  });
button("new").onclick = () => {
  if (busy) return;
  persist();
  session = undefined;
  order = undefined;
  payment = "";
  for (const id of ["amount", "recipient", "refund"]) input(id).value = "";
  direction();
  persist();
  el("order-details").hidden = true;
  text("status", "No order yet.");
  text("error", "");
  text("message", "");
  controls();
};
button("copy").onclick = () =>
  void attempt(async () => {
    if (!session?.id) return;
    await navigator.clipboard.writeText(
      `${location.origin}/#order=${encodeURIComponent(session.id)}&cap=${session.capability}`,
    );
    text("message", "Private recovery link copied.");
  });
button("copy-payment").onclick = () =>
  void attempt(async () => {
    await navigator.clipboard.writeText(payment);
    text("message", "Payment instructions copied.");
  });
el<HTMLSelectElement>("history").onchange = () =>
  void attempt(async () => {
    if (!el<HTMLSelectElement>("history").value) {
      el<HTMLSelectElement>("history").value = session?.id || "";
      return;
    }
    session = history.find(
      (s) => s.id === el<HTMLSelectElement>("history").value,
    );
    persist();
    await refresh();
  });
direction();
if (session?.request) showRequest(session.request);
persist();
void attempt(async () => {
  await loadConfig();
  await refresh();
});
setInterval(() => {
  if (!busy)
    void attempt(async () => {
      await loadConfig();
      await refresh();
    });
}, 15000);
