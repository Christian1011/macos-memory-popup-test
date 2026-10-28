// node lsp-probe.mjs FILE.ts LOG: keeps one tsserver warm on FILE's project.
// Logs the first quickinfo (project load) and, on each SIGUSR2, a fresh quickinfo latency and tsserver RSS.
import { spawn, execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { createRequire } from "node:module";

const [file, log] = process.argv.slice(2);
const tsserver = createRequire(import.meta.url).resolve("typescript/lib/tsserver.js");
const ts = spawn(process.execPath, [tsserver, "--disableAutomaticTypingAcquisition"], { stdio: ["pipe", "pipe", "inherit"] });
const note = (line) => appendFileSync(log, `${new Date().toISOString()} ${line}\n`);
const rssMB = () => Math.round(Number(execFileSync("ps", ["-o", "rss=", "-p", String(ts.pid)]).toString()) / 1024);

let seq = 0, buf = "";
const pending = new Map();
ts.stdout.on("data", (chunk) => {
  buf += chunk;
  for (let i; (i = buf.indexOf("\n{")) !== -1 || buf.startsWith("{"); ) {
    const start = buf.startsWith("{") ? 0 : i + 1, end = buf.indexOf("\n", start);
    if (end === -1) break;
    const msg = JSON.parse(buf.slice(start, end));
    buf = buf.slice(end + 1);
    if (msg.type === "response" && pending.has(msg.request_seq)) pending.get(msg.request_seq)(msg), pending.delete(msg.request_seq);
  }
});
const ask = (command, args) => new Promise((done) => {
  pending.set(++seq, done);
  ts.stdin.write(JSON.stringify({ seq, type: "request", command, arguments: args }) + "\n");
});
const probe = async (label) => {
  const t = performance.now();
  await ask("quickinfo", { file, line: 1, offset: 1 });
  note(`${label} quickinfo ${Math.round(performance.now() - t)} ms, tsserver rss ${rssMB()} MB, pid ${ts.pid}`);
};

ts.stdin.write(JSON.stringify({ seq: ++seq, type: "request", command: "open", arguments: { file } }) + "\n");
await probe("first (project load)");
process.on("SIGUSR2", () => probe("again"));
setInterval(() => {}, 1 << 30);
