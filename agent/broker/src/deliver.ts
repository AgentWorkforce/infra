/**
 * Out-of-band delivery. Credentials never travel in a Relay message: the
 * broker writes them somewhere only the requester can read and replies with a
 * pointer (a file path or a 1Password item id) plus the expiry.
 *
 *  - file: a credential_process JSON file, 0600, under
 *    <root>/<agent>/<request-id>.json. For requesters on the broker's own
 *    node (its workers). Use it with
 *    `credential_process = cat <path>` in ~/.aws/config.
 *  - 1password: an API Credential item in a vault the requester's 1Password
 *    service account can read, created with the template on stdin (never on
 *    the command line). For requesters on another node (linuyc).
 *
 * Both are removed by `sweep` after the credentials expire.
 */
import { execFile } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Delivery } from "./policy.ts";
import type { SessionCredentials } from "./sts.ts";

export interface DeliveryRef {
  kind: Delivery["kind"];
  /** Where the requester reads it: a path, or op://<vault>/<item id>. Not a secret. */
  ref: string;
}

export interface Deliverer {
  deliver(d: Delivery, agent: string, requestId: string, creds: SessionCredentials): Promise<DeliveryRef>;
  remove(ref: DeliveryRef): Promise<void>;
}

export function credentialProcessJson(c: SessionCredentials): string {
  return JSON.stringify({ Version: 1, AccessKeyId: c.accessKeyId, SecretAccessKey: c.secretAccessKey, SessionToken: c.sessionToken, Expiration: c.expiration }) + "\n";
}

export function onePasswordTemplate(agent: string, requestId: string, c: SessionCredentials): string {
  return JSON.stringify({
    title: `aws-broker ${requestId}`,
    category: "API_CREDENTIAL",
    tags: ["aws-cred-broker", `agent:${agent}`],
    fields: [
      { id: "aws_access_key_id", label: "AWS_ACCESS_KEY_ID", type: "STRING", value: c.accessKeyId },
      { id: "aws_secret_access_key", label: "AWS_SECRET_ACCESS_KEY", type: "CONCEALED", value: c.secretAccessKey },
      { id: "aws_session_token", label: "AWS_SESSION_TOKEN", type: "CONCEALED", value: c.sessionToken },
      { id: "expiration", label: "EXPIRATION", type: "STRING", value: c.expiration },
      { id: "credential_process", label: "credential_process", type: "CONCEALED", value: credentialProcessJson(c).trim() },
    ],
  });
}

const SAFE = /^[\w.@=+,-]{1,64}$/;

export type OpRunner = (args: string[], stdin?: string) => Promise<string>;

export function opCli(): OpRunner {
  return (args, stdin) =>
    new Promise((resolve, reject) => {
      const child = execFile("op", args, { maxBuffer: 1 << 20 }, (err, stdout, stderr) => {
        if (err) reject(new Error(`op ${args[0]} ${args[1]} failed: ${String(stderr).trim().split("\n").at(-1) ?? err.message}`));
        else resolve(stdout);
      });
      if (stdin !== undefined) child.stdin?.end(stdin);
    });
}

export function defaultDeliverer(fileRoot: string, op: OpRunner = opCli()): Deliverer {
  return {
    async deliver(d, agent, requestId, creds) {
      if (!SAFE.test(agent) || !SAFE.test(requestId)) throw new Error("delivery: unsafe agent or request id");
      if (d.kind === "file") {
        const dir = join(fileRoot, agent);
        mkdirSync(dir, { recursive: true, mode: 0o700 });
        chmodSync(dir, 0o700);
        const path = join(dir, `${requestId}.json`);
        const tmp = `${path}.tmp`;
        writeFileSync(tmp, credentialProcessJson(creds), { mode: 0o600, flag: "wx" });
        renameSync(tmp, path);
        return { kind: "file", ref: path };
      }
      const out = await op(["item", "create", "--vault", d.vault, "--format", "json", "-"], onePasswordTemplate(agent, requestId, creds));
      const id = (JSON.parse(out) as { id?: string }).id;
      if (!id || !SAFE.test(id)) throw new Error("delivery: 1Password returned no item id");
      return { kind: "1password", ref: `op://${d.vault}/${id}` };
    },
    async remove(ref) {
      if (ref.kind === "file") {
        if (existsSync(ref.ref)) rmSync(ref.ref);
        return;
      }
      const m = /^op:\/\/([^/]+)\/([^/]+)$/.exec(ref.ref);
      if (!m) throw new Error(`delivery: bad 1Password ref ${ref.ref}`);
      await op(["item", "delete", m[2]!, "--vault", m[1]!]);
    },
  };
}
