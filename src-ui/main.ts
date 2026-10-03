type Disk = { device: string; size: string; name: string; kind: "nvme" | "mmc" | "other" };
type Status = {
  device: { chip: string; product: string | null } | null;
  rpiboot: string | null;
  disks: Disk[];
  usb_error: string | null;
};

declare global {
  interface Window {
    __TAURI__: { core: { invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> } };
  }
}

const { invoke } = window.__TAURI__.core;
const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const isMac = navigator.userAgent.includes("Mac");

let strings: Record<string, string> = {};
const t = (key: string, vars: Record<string, string> = {}) =>
  (strings[key] ?? key).replace(/\{(\w+)\}/g, (_, k: string) => vars[k] ?? "");

let running = false;
let last: Status | null = null;

function setDot(id: string, state: "ok" | "warn" | "wait") {
  $(id).className = `dot ${state === "wait" ? "" : state}`;
}

function log(text: string) {
  const el = $<HTMLPreElement>("log");
  el.textContent = `${el.textContent === t("log.empty") ? "" : el.textContent}${text.trimEnd()}\n`;
  el.scrollTop = el.scrollHeight;
}

function render(s: Status) {
  last = s;
  const device = s.device;
  setDot("device-dot", device ? "ok" : "wait");
  $("device-text").textContent = device
    ? t("device.found", { chip: device.product ? `${device.chip} (${device.product})` : device.chip })
    : s.usb_error
      ? t("error.usb", { error: s.usb_error })
      : t("device.waiting");
  $("device-help").hidden = !!device;

  setDot("rpiboot-dot", s.rpiboot ? "ok" : "warn");
  $("rpiboot-text").textContent = s.rpiboot ? t("rpiboot.found", { path: s.rpiboot }) : t("rpiboot.missing");
  const install = $("rpiboot-install");
  install.hidden = !!s.rpiboot;
  install.textContent = isMac ? "brew install rpiboot" : "sudo apt install rpiboot";

  const list = $("disks");
  list.replaceChildren(
    ...(s.disks.length ? s.disks : [null]).map((d) => {
      const li = document.createElement("li");
      if (!d) {
        li.className = "muted";
        li.textContent = t("disks.none");
        return li;
      }
      const badge = document.createElement("span");
      badge.className = `badge ${d.kind}`;
      badge.textContent = t(`kind.${d.kind}`);
      const label = document.createElement("span");
      label.textContent = `${d.size} · ${d.device} · ${d.name}`;
      li.append(badge, label);
      return li;
    }),
  );
  const hasNvme = s.disks.some((d) => d.kind === "nvme");
  setDot("disks-dot", hasNvme ? "ok" : s.disks.length ? "warn" : "wait");
  $("mmc-hint").hidden = hasNvme || !s.disks.some((d) => d.kind === "mmc");

  $<HTMLButtonElement>("start").disabled = running || !device || !s.rpiboot;
}

async function refresh() {
  try {
    render(await invoke<Status>("status"));
  } catch (e) {
    log(String(e));
  }
}

async function start() {
  running = true;
  const button = $<HTMLButtonElement>("start");
  button.textContent = t("action.running");
  if (last) render(last);
  try {
    log(await invoke<string>("start_gadget", { forcePcie: $<HTMLInputElement>("pcie").checked }));
    log(t("result.ok"));
  } catch (e) {
    const msg = String(e);
    log(strings[`error.${msg}`] ? t(`error.${msg}`) : `${msg}\n${t("result.fail")}`);
  } finally {
    running = false;
    button.textContent = t("action.start");
    await refresh();
  }
}

async function openImager() {
  try {
    await invoke("open_imager");
  } catch (e) {
    log(t(`error.${String(e)}`));
  }
}

async function main() {
  const lang = navigator.language.toLowerCase().startsWith("tr") ? "tr" : "en";
  strings = await (await fetch(`i18n/${lang}.json`)).json();
  document.documentElement.lang = lang;
  document.querySelectorAll<HTMLElement>("[data-i18n]").forEach((el) => {
    el.textContent = t(el.dataset.i18n!);
  });
  $("log").textContent = t("log.empty");
  $("start").addEventListener("click", start);
  $("imager").addEventListener("click", openImager);
  await refresh();
  // ponytail: 1.5 s polling of USB + diskutil/lsblk; switch to hotplug events if it ever shows up in CPU use.
  setInterval(() => void refresh(), 1500);
}

void main();

export {};
