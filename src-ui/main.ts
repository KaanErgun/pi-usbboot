type Disk = { device: string; size: string; name: string; kind: "nvme" | "mmc" | "other" };
type Status = {
  device: { chip: string; product: string | null; mode: "legacy" | "modern" } | null;
  rpiboot: string | null;
  imager_ready: boolean;
  boot_files: string | null;
  boot_error: string | null;
  ready: boolean;
  disks: Disk[];
  usb_error: string | null;
};

declare global {
  interface Window {
    __TAURI__: {
      core: { invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> };
      app: { getVersion(): Promise<string> };
    };
  }
}

const { invoke } = window.__TAURI__.core;
const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

let strings: Record<string, string> = {};
const t = (key: string, vars: Record<string, string> = {}) =>
  (strings[key] ?? key).replace(/\{(\w+)\}/g, (_, k: string) => vars[k] ?? "");

let running = false;
let last: Status | null = null;
let refreshSequence = 0;
let lastRefresh = 0;
let diskWaitTimedOut = false;
let diskWait: {
  baseline: Set<string>;
  afterRefresh: number;
  timer: ReturnType<typeof setTimeout>;
} | null = null;

function finishDiskWait(disk: Disk | null) {
  if (!diskWait) return;
  clearTimeout(diskWait.timer);
  diskWait = null;
  diskWaitTimedOut = disk === null;
  running = false;
  $("start").textContent = t("action.start");
  log(t(disk ? "result.disk-found" : "result.disk-timeout", { device: disk?.device ?? "" }));
  if (last) {
    render(last);
  } else if (!disk) {
    const message = document.createElement("li");
    message.className = "hint";
    message.textContent = t("result.disk-timeout");
    $("disks").replaceChildren(message);
    setDot("disks-dot", "warn");
  }
}

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
  setDot("device-dot", device ? "ok" : s.usb_error ? "warn" : "wait");
  $("device-text").textContent = device
    ? t("device.found", { chip: device.product ? `${device.chip} (${device.product})` : device.chip })
    : s.usb_error
      ? strings[`error.${s.usb_error}`] ? t(`error.${s.usb_error}`) : t("error.usb", { error: s.usb_error })
      : t("device.waiting");
  $("device-help").hidden = !!device;

  setDot("rpiboot-dot", s.rpiboot && s.imager_ready ? "ok" : "warn");
  $("rpiboot-text").textContent = s.rpiboot && s.imager_ready ? t("rpiboot.found") : t("rpiboot.missing");
  $<HTMLButtonElement>("imager").disabled = !s.imager_ready;

  $("mode-text").textContent = t(device ? `mode.${device.mode}` : "mode.waiting");
  const bootError = s.boot_error && s.boot_error !== "device-missing" && s.boot_error !== "rpiboot-missing"
    ? s.boot_error
    : null;
  setDot("boot-dot", bootError === "busy" ? "wait" : bootError ? "warn" : s.boot_files ? "ok" : "wait");
  $("boot-text").textContent = bootError
    ? t(`error.${bootError}`)
    : s.boot_files ? t("boot.ready") : t("boot.waiting");
  $("boot-text").hidden = !device && !bootError;
  $("boot-help").hidden = bootError !== "legacy-boot-files-missing" && bootError !== "modern-boot-files-missing";

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
  if (diskWait || diskWaitTimedOut) {
    const message = document.createElement("li");
    message.className = diskWaitTimedOut ? "hint" : "muted";
    message.textContent = t(diskWait ? "disks.waiting" : "result.disk-timeout");
    list.prepend(message);
  }
  setDot("disks-dot", diskWait ? "wait" : diskWaitTimedOut ? "warn" : s.disks.length ? "ok" : "wait");

  const button = $<HTMLButtonElement>("start");
  button.disabled = running || !s.ready;
  button.textContent = t(diskWait ? "action.waiting" : running ? "action.running" : "action.start");
}

async function refresh() {
  const request = ++refreshSequence;
  try {
    const status = await invoke<Status>("status");
    if (request < lastRefresh) return;
    lastRefresh = request;
    // Only a fresh post-transfer poll may confirm a newly enumerated disk.
    // Existing USB disks are unrelated to this attempt and never confirm it.
    if (diskWait && request > diskWait.afterRefresh) {
      const disk = status.disks.find((disk) => !diskWait!.baseline.has(disk.device));
      if (disk) finishDiskWait(disk);
    }
    render(status);
  } catch (e) {
    if (request < lastRefresh) return;
    lastRefresh = request;
    last = null;
    $<HTMLButtonElement>("imager").disabled = true;
    $<HTMLButtonElement>("start").disabled = true;
    log(String(e));
  }
}

async function start() {
  if (running || !last?.ready) return;
  running = true;
  diskWaitTimedOut = false;
  if (last) render(last);
  try {
    // Snapshot immediately before booting, rather than using a possibly stale
    // UI poll that could miss an unrelated drive connected before the attempt.
    const before = await invoke<Status>("status");
    const baseline = new Set(before.disks.map((disk) => disk.device));
    log(await invoke<string>("start_gadget"));
    log(t("result.transferred"));
    diskWait = {
      baseline,
      afterRefresh: refreshSequence,
      timer: setTimeout(() => finishDiskWait(null), 45_000),
    };
  } catch (e) {
    running = false;
    const msg = String(e);
    log(strings[`error.${msg}`] ? t(`error.${msg}`) : `${msg}\n${t("result.fail")}`);
  } finally {
    if (last) render(last);
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
  $("version").textContent = `v${await window.__TAURI__.app.getVersion()}`;
  $("start").addEventListener("click", start);
  $("imager").addEventListener("click", openImager);
  await refresh();
  // ponytail: 1.5 s polling of USB + diskutil/lsblk; switch to hotplug events if it ever shows up in CPU use.
  setInterval(() => void refresh(), 1500);
}

void main();

export {};
