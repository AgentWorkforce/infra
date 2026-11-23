/**
 * Where owner-delegate grants come from. An owner delegate is a Relay agent a
 * human approver has named as their delegate (policy.ts
 * checkOwnerDelegateApproval). Who that is never goes in this repo: the
 * allowlist only switches the rule on and names the source.
 *
 * The one source today is a JSON file on the broker host, installed by the
 * owner as root:
 *   { "version": 1, "grantedBy": "<human approver>",
 *     "delegates": [ { "agentId": "<Relay agent id>", "expiresAt": "<ISO 8601 UTC>", "note": "…" } ] }
 * It grants nothing (with the reason) unless it is a regular file, not a
 * symlink, owned by root, not writable by group or others, valid JSON of this
 * shape, and from the allowlist's ownerDelegates.grantedBy. A bad entry is
 * dropped and the others stay. `note` is for the owner and is never read.
 *
 * A source that reads the owner's grants from the Relay platform would replace
 * the file behind the same interface. Relay has no such read path yet, so none
 * is written here (DESIGN.md).
 */
import { closeSync, constants, fstatSync, openSync, readFileSync } from "node:fs";
import { MAX_DELEGATION_DAYS, ownerDelegatesProblems, type Allowlist, type OwnerDelegateGrant, type OwnerDelegateGrants } from "./policy.ts";

export const DEFAULT_OWNER_DELEGATES_FILE = "/etc/aws-cred-broker/owner-delegates.json";

/** A grant file is a few lines: anything bigger is not one. */
const MAX_FILE_BYTES = 64 * 1024;

export interface OwnerDelegateSource {
  /** The allowlist's ownerDelegates.source this implements. */
  kind: string;
  /** Where it reads from, for the operator (a path). */
  where: string;
  /** The grants that are live at `now`. Never throws: a source that can't be read grants nothing and says why. */
  load(now: Date): OwnerDelegateGrants;
}

/** The source of a broker that was given none: no grants. */
export const noOwnerDelegates: OwnerDelegateSource = {
  kind: "none",
  where: "",
  load: () => ({ grants: [], problems: ["no owner-delegate source is configured"] }),
};

/** What the broker checks about the grant file before it reads it. */
export interface FileFacts {
  uid: number;
  mode: number;
  isFile: boolean;
  size: number;
}

/** The facts of the open file itself (fstat), so what is checked is what is read. */
export function fileFacts(fd: number): FileFacts {
  const s = fstatSync(fd);
  return { uid: s.uid, mode: s.mode, isFile: s.isFile(), size: s.size };
}

/**
 * Grants from a root-owned JSON file on the broker host. `facts` is
 * injectable so tests can run without root; the broker always uses fileFacts.
 */
export function hostFileSource(path: string, list: Allowlist, facts: (fd: number) => FileFacts = fileFacts): OwnerDelegateSource {
  const none = (problem: string): OwnerDelegateGrants => ({ grants: [], problems: [problem] });
  return {
    kind: "host-file",
    where: path,
    load(now) {
      const o = list.ownerDelegates;
      if (o === undefined) return none("the allowlist has no ownerDelegates block");
      const config = ownerDelegatesProblems(list);
      if (config.length) return none(config.join("; "));
      let text: string;
      let fd: number;
      try {
        // O_NOFOLLOW: a symlink is refused, never followed.
        fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
      } catch (e) {
        const code = (e as NodeJS.ErrnoException).code;
        return none(code === "ENOENT" ? `${path} is missing` : code === "ELOOP" ? `${path} is a symlink` : `${path} is unreadable (${code ?? "error"})`);
      }
      try {
        const f = facts(fd);
        if (!f.isFile) return none(`${path} is not a regular file`);
        if (f.uid !== 0) return none(`${path} is not owned by root`);
        if (f.mode & 0o022) return none(`${path} is writable by group or others`);
        if (f.size > MAX_FILE_BYTES) return none(`${path} is too large to be a grant file`);
        text = readFileSync(fd, "utf8");
      } catch (e) {
        return none(`${path} is unreadable (${(e as NodeJS.ErrnoException).code ?? "error"})`);
      } finally {
        closeSync(fd);
      }
      let file: unknown;
      try {
        file = JSON.parse(text);
      } catch {
        return none(`${path} is not valid JSON`);
      }
      if (!file || typeof file !== "object" || Array.isArray(file)) return none(`${path} is not a JSON object`);
      const f = file as Record<string, unknown>;
      if (f.version !== 1) return none(`${path}: version must be 1`);
      if (f.grantedBy !== o.grantedBy) return none(`${path}: grantedBy is not ${o.grantedBy}, the allowlist's ownerDelegates.grantedBy`);
      if (!Array.isArray(f.delegates)) return none(`${path}: delegates must be a list`);
      const problems: string[] = [];
      const seen = new Map<string, number>();
      for (const e of f.delegates as unknown[]) {
        const id = e && typeof e === "object" ? (e as Record<string, unknown>).agentId : undefined;
        if (typeof id === "string") seen.set(id, (seen.get(id) ?? 0) + 1);
      }
      const grants: OwnerDelegateGrant[] = [];
      (f.delegates as unknown[]).forEach((e, i) => {
        // Entries are named by position: a problem never repeats a name or a note.
        const drop = (why: string) => problems.push(`${path}: delegates[${i}] dropped: ${why}`);
        if (!e || typeof e !== "object" || Array.isArray(e)) return drop("not an object");
        const { agentId, expiresAt } = e as Record<string, unknown>;
        if (typeof agentId !== "string" || !/^[0-9]{6,32}$/.test(agentId)) return drop("agentId must be a Relay agent id");
        if ((seen.get(agentId) ?? 0) > 1) return drop("its agentId is listed more than once");
        if (typeof expiresAt !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(expiresAt) || Number.isNaN(Date.parse(expiresAt))) return drop("expiresAt must be an ISO 8601 UTC time");
        const expires = Date.parse(expiresAt);
        if (!(now.getTime() < expires)) return drop(`expired at ${expiresAt}`);
        if (expires - now.getTime() > MAX_DELEGATION_DAYS * 86_400_000) return drop(`expiresAt is more than ${MAX_DELEGATION_DAYS} days away`);
        grants.push({ agentId, expiresAt, grantedBy: o.grantedBy, source: o.source });
      });
      return { grants, problems };
    },
  };
}
