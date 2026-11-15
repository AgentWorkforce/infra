/**
 * One broker run at a time, by a kernel lock: flock(1) (util-linux, on every
 * Linux host and CI runner) holds an exclusive lock on <state>/.lock for as
 * long as its child reads our stdin. We release by closing that pipe. If this
 * process dies, however it dies, the pipe closes, the child exits and the
 * kernel drops the lock. So there is no stale lock to detect or take over, and
 * no way for one run to remove another's.
 *
 * Every external call the lock covers has a timeout (sts.ts, deliver.ts), so a
 * live holder can't keep it forever.
 */
import { spawn } from "node:child_process";
import { join } from "node:path";

export async function withLock<T>(dir: string, fn: () => Promise<T>, waitMs = 60_000): Promise<T> {
  const child = spawn("flock", ["--exclusive", "--timeout", String(waitMs / 1000), join(dir, ".lock"), "sh", "-c", "echo locked; exec cat >/dev/null"], {
    stdio: ["pipe", "pipe", "ignore"],
  });
  const exited = new Promise<number | null>((resolve) => child.on("exit", resolve));
  await new Promise<void>((resolve, reject) => {
    let out = "";
    child.stdout.on("data", (d: Buffer) => {
      out += d.toString();
      if (out.includes("locked")) resolve();
    });
    child.on("error", (e) => reject(new Error(`broker: cannot run flock (util-linux): ${e.message}`)));
    void exited.then((code) => reject(new Error(code === 1 ? "broker: state is locked by another run" : `broker: flock exited with ${code}`)));
  });
  try {
    return await fn();
  } finally {
    child.stdin.end();
    await exited;
  }
}
