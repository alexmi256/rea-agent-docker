// MCP stdio probe: speaks the same protocol Hermes does over
// `docker exec -i <container> rea mcp`.
//
//   1. initialize            -> server identity + protocol version
//   2. tools/list            -> the tool catalog (REA ships 170+ tools)
//   3. tools/call            -> a real, engine-free inspection (SQLite)
//   4. optional: open a binary through a provider, analyse, close
//
// Prints a JSON summary on stdout; exits non-zero on any protocol failure.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";

const serverCmd = process.env.REA_MCP_SERVER ?? "rea";
const serverArgs = (process.env.REA_MCP_ARGS ?? "mcp").split(" ").filter(Boolean);
const sqlitePath = process.env.REA_VERIFY_SQLITE ?? "/tmp/rea-verify/fixtures/fixture.sqlite";
const jsappDir = process.env.REA_VERIFY_JSAPP ?? "/tmp/rea-verify/fixtures/jsapp";
const binaryPath = process.env.REA_VERIFY_BINARY ?? "/tmp/rea-verify/fixtures/fixture-x86_64.elf";
const provider = process.env.REA_VERIFY_PROVIDER ?? "ghidra";
const doAnalysis = (process.env.REA_VERIFY_MCP_ANALYSIS ?? "1") === "1";
const overallTimeoutMs = Number(process.env.REA_VERIFY_MCP_TIMEOUT_MS ?? 900000);

const child = spawn(serverCmd, serverArgs, { stdio: ["pipe", "pipe", "pipe"] });
child.on("error", (err) => {
    console.error(`spawn failed: ${err.message}`);
    process.exit(2);
});

let stderrTail = "";
child.stderr.on("data", (d) => { stderrTail = (stderrTail + d.toString()).slice(-4000); });

const pending = new Map();
let buffer = "";
child.stdout.on("data", (chunk) => {
    buffer += chunk.toString();
    let idx;
    while ((idx = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, idx).trim();
        buffer = buffer.slice(idx + 1);
        if (!line) continue;
        let msg;
        try { msg = JSON.parse(line); } catch { continue; }
        if (msg.id !== undefined && pending.has(msg.id)) {
            const { resolve, reject } = pending.get(msg.id);
            pending.delete(msg.id);
            if (msg.error) reject(new Error(JSON.stringify(msg.error)));
            else resolve(msg.result);
        }
    }
});

let nextId = 1;
function request(method, params) {
    const id = nextId++;
    const payload = { jsonrpc: "2.0", id, method, params };
    child.stdin.write(`${JSON.stringify(payload)}\n`);
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            pending.delete(id);
            reject(new Error(`timeout waiting for ${method}`));
        }, overallTimeoutMs);
        pending.set(id, {
            resolve: (v) => { clearTimeout(timer); resolve(v); },
            reject: (e) => { clearTimeout(timer); reject(e); },
        });
    });
}
function notify(method, params) {
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
}

const summary = { steps: {}, tools: { count: 0, sample: [] } };

try {
    const init = await request("initialize", {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "rea-agent-verify", version: "1.0.0" },
    });
    summary.steps.initialize = {
        serverInfo: init?.serverInfo ?? null,
        protocolVersion: init?.protocolVersion ?? null,
        capabilities: Object.keys(init?.capabilities ?? {}),
    };
    notify("notifications/initialized", {});

    const tools = await request("tools/list", {});
    const names = (tools?.tools ?? []).map((t) => t.name);
    summary.steps["tools/list"] = { count: names.length };
    summary.tools.count = names.length;
    summary.tools.sample = names.slice(0, 12);
    if (names.length < 50) throw new Error(`tool catalog suspiciously small: ${names.length}`);

    if (existsSync(sqlitePath)) {
        const candidates = [
            { tool: "inspect_artifact", path: jsappDir, args: { path: jsappDir }, expect: /package\.json|src|jsapp|artifact/i },
            { tool: "inspect_sqlite_database", path: sqlitePath, args: { path: sqlitePath, table: "settings", row_limit: 5 }, expect: /settings|license_requests/ },
            { tool: "inspect_binary_layout", path: binaryPath, args: { path: binaryPath }, expect: /main|section|segment/i },
        ];
        const chosen = candidates.find((c) => names.includes(c.tool) && existsSync(c.path));
        if (!chosen) {
            summary.steps["tools/call:engine-free"] = { skipped: "no engine-free tool in this release" };
        } else {
            const call = await request("tools/call", { name: chosen.tool, arguments: chosen.args });
            const text = (call?.content ?? []).map((c) => c.text ?? "").join("\n");
            summary.steps[`tools/call:${chosen.tool}`] = {
                isError: Boolean(call?.isError),
                matched: chosen.expect.test(text),
                bytes: text.length,
            };
            if (call?.isError || !chosen.expect.test(text)) {
                throw new Error(`tools/call ${chosen.tool} did not return usable data`);
            }
        }
    } else {
        summary.steps["tools/call:engine-free"] = { skipped: "fixture missing" };
    }

    if (doAnalysis && existsSync(binaryPath)) {
        const open = await request("tools/call", {
            name: "open_binary",
            arguments: { path: binaryPath, provider_id: provider },
        });
        summary.steps[`tools/call:open_binary(${provider})`] = { isError: Boolean(open?.isError) };
        if (open?.isError) throw new Error(`open_binary failed: ${JSON.stringify(open).slice(0, 400)}`);

        const fn = await request("tools/call", { name: "analyze_function", arguments: { procedure: "main" } });
        const fnText = (fn?.content ?? []).map((c) => c.text ?? "").join("\n");
        summary.steps[`tools/call:analyze_function(${provider})`] = {
            isError: Boolean(fn?.isError),
            mentionsMain: /main/i.test(fnText),
            bytes: fnText.length,
        };

        const close = await request("tools/call", { name: "close_binary", arguments: {} });
        summary.steps[`tools/call:close_binary(${provider})`] = { isError: Boolean(close?.isError) };
    } else {
        summary.steps["tools/call:open_binary"] = { skipped: "analysis disabled or fixture missing" };
    }

    summary.ok = true;
    console.log(JSON.stringify(summary, null, 2));
    child.stdin.end();
    child.kill();
    process.exit(0);
} catch (err) {
    summary.ok = false;
    summary.error = String(err?.message ?? err);
    summary.stderrTail = stderrTail;
    console.log(JSON.stringify(summary, null, 2));
    child.kill();
    process.exit(1);
}
