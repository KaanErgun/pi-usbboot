#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";
import ts from "typescript";

const source = readFileSync(new URL("../src-ui/main.ts", import.meta.url), "utf8");
const compiled = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 },
}).outputText.replace("void main();", "globalThis.initialized = main();").replace(/export \{\};?/, "");
const disk = (device) => ({ device, name: "USB disk", size: "32 GB", kind: "other" });
const status = (disks = []) => ({
  device: { chip: "BCM2712", product: null, mode: "modern" },
  rpiboot: "/bundled/rpiboot", imager_ready: true, boot_files: "/bundled/payload",
  boot_error: null, ready: true, disks, usb_error: null,
});

async function app(language = "en", initialDisks = []) {
  const strings = JSON.parse(readFileSync(new URL(`../ui/i18n/${language}.json`, import.meta.url)));
  const elements = new Map();
  const element = () => ({
    textContent: "", className: "", hidden: false, disabled: false, children: [],
    replaceChildren(...children) { this.children = children; },
    append(...children) { this.children.push(...children); },
    prepend(...children) { this.children.unshift(...children); },
    addEventListener() {},
  });
  const get = (id) => {
    if (!elements.has(id)) elements.set(id, element());
    return elements.get(id);
  };
  const timers = new Map();
  let timerId = 0;
  const state = {
    current: status(initialDisks),
    readStatus: () => Promise.resolve(state.current),
    transfer: () => Promise.resolve("Second stage boot server done"),
    starts: 0,
  };
  const context = vm.createContext({
    window: { __TAURI__: {
      core: { invoke: (command) => {
        if (command === "status") return state.readStatus();
        if (command === "start_gadget") { state.starts++; return state.transfer(); }
        throw new Error(`Unexpected command: ${command}`);
      } },
      app: { getVersion: async () => "test" },
    } },
    document: { getElementById: get, createElement: element, querySelectorAll: () => [], documentElement: {} },
    navigator: { language },
    fetch: async () => ({ json: async () => strings }),
    setInterval: () => 1,
    setTimeout: (callback, delay) => { const id = ++timerId; timers.set(id, { callback, delay }); return id; },
    clearTimeout: (id) => timers.delete(id),
  });
  vm.runInContext(compiled, context);
  await context.initialized;
  return {
    state, strings, get, timers,
    start: () => context.start(), refresh: () => context.refresh(),
    timeout: () => {
      const timer = [...timers.values()][0];
      assert.equal(timer.delay, 45_000);
      timer.callback();
    },
  };
}

for (const language of ["en", "tr"]) {
  test(`${language}: transfer completion waits; existing disks cannot confirm storage`, async () => {
    const ui = await app(language, [disk("/dev/disk2")]);
    // A drive connected after the last UI poll, before starting, belongs in the baseline too.
    ui.state.current = status([disk("/dev/disk2"), disk("/dev/disk3")]);
    await ui.start();
    assert.equal(ui.get("start").textContent, ui.strings["action.waiting"]);
    assert.equal(ui.get("start").disabled, true);
    assert.equal(ui.get("disks-dot").className, "dot ");
    assert.ok(ui.get("log").textContent.includes(ui.strings["result.transferred"]));
    assert.ok(!ui.get("log").textContent.includes("/dev/disk3"));
    await ui.start();
    assert.equal(ui.state.starts, 1);
    ui.timeout();
    assert.ok(ui.get("log").textContent.includes(ui.strings["result.disk-timeout"]));
    assert.equal(ui.get("disks-dot").className, "dot warn");
    assert.equal(ui.get("start").textContent, ui.strings["action.start"]);
  });
}

test("a fresh new disk confirms detection once and cancels the timeout", async () => {
  const ui = await app("en", [disk("/dev/disk2")]);
  await ui.start();
  ui.state.current = status([disk("/dev/disk2"), disk("/dev/disk4")]);
  await ui.refresh();
  assert.ok(ui.get("log").textContent.includes(ui.strings["result.disk-found"].replace("{device}", "/dev/disk4")));
  assert.equal(ui.timers.size, 0);
  assert.equal(ui.get("disks-dot").className, "dot ok");
  const log = ui.get("log").textContent;
  await ui.refresh();
  assert.equal(ui.get("log").textContent, log);
});

test("timeout remains bounded when status polling fails", async () => {
  const ui = await app();
  await ui.start();
  ui.state.readStatus = () => Promise.reject(new Error("Status unavailable"));
  await ui.refresh();
  ui.timeout();
  assert.ok(ui.get("log").textContent.includes(ui.strings["result.disk-timeout"]));
  assert.equal(ui.get("start").textContent, ui.strings["action.start"]);
  assert.equal(ui.get("disks").children[0].textContent, ui.strings["result.disk-timeout"]);
  assert.equal(ui.get("disks-dot").className, "dot warn");
  assert.equal(ui.get("start").disabled, true);
  assert.equal(ui.get("imager").disabled, true);
});

test("failed transfers never start a disk wait", async () => {
  const ui = await app();
  ui.state.transfer = () => Promise.reject("device-missing");
  await ui.start();
  assert.equal(ui.timers.size, 0);
  assert.ok(ui.get("log").textContent.includes(ui.strings["error.device-missing"]));
  assert.ok(!ui.get("log").textContent.includes(ui.strings["result.transferred"]));
});

test("an old pending status response cannot confirm a post-transfer disk", async () => {
  const ui = await app();
  let resolveOld;
  ui.state.readStatus = () => new Promise((resolve) => { resolveOld = resolve; });
  const oldPoll = ui.refresh();
  ui.state.readStatus = () => Promise.resolve(ui.state.current);
  await ui.start();
  resolveOld(status([disk("/dev/disk9")]));
  await oldPoll;
  assert.equal(ui.get("start").textContent, ui.strings["action.waiting"]);
  assert.equal(ui.timers.size, 1);
  assert.ok(!ui.get("log").textContent.includes("/dev/disk9"));
});
