/**
 * STS vending. The broker host's AWS profile (default "aws-cred-broker")
 * assumes the broker role; from that role, one AssumeRole per request into the
 * target account's role, with:
 *  - RoleSessionName and SourceIdentity = the requesting agent's name, so
 *    every CloudTrail event names the agent (SourceIdentity survives any
 *    further role chaining and can't be changed by the session);
 *  - session tags broker-request-id, agent-run and agent, which the target
 *    role's trust policy requires and its permissions use for ABAC;
 *  - the inline session policy from the policy engine, which narrows the
 *    role's own policy to this request.
 *
 * The default client shells out to the AWS CLI already on the host (no new
 * dependency). Credentials come back on a pipe and stay in memory: they are
 * never logged, never passed on a command line.
 */
import { execFile } from "node:child_process";
import type { SessionPolicy } from "./policy.ts";

export interface AssumeInput {
  roleArn: string;
  sessionName: string;
  sourceIdentity: string;
  durationSeconds: number;
  policy: SessionPolicy;
  tags: Record<string, string>;
}

export interface SessionCredentials {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken: string;
  expiration: string;
}

export interface StsClient {
  assumeRole(input: AssumeInput): Promise<SessionCredentials>;
}

export function assumeRoleArgs(input: AssumeInput, profile: string): string[] {
  const args = [
    "sts",
    "assume-role",
    "--profile",
    profile,
    "--output",
    "json",
    "--role-arn",
    input.roleArn,
    "--role-session-name",
    input.sessionName,
    "--source-identity",
    input.sourceIdentity,
    "--duration-seconds",
    String(input.durationSeconds),
    "--policy",
    JSON.stringify(input.policy),
    "--tags",
    ...Object.entries(input.tags).map(([k, v]) => `Key=${k},Value=${v}`),
  ];
  return args;
}

/** An STS call that takes longer is killed: the broker never holds its lock on an unbounded call. */
export const STS_TIMEOUT_MS = 30_000;

export function awsCliSts(profile = process.env.BROKER_AWS_PROFILE ?? "aws-cred-broker"): StsClient {
  return {
    assumeRole(input) {
      return new Promise((resolve, reject) => {
        execFile("aws", assumeRoleArgs(input, profile), { maxBuffer: 1 << 20, timeout: STS_TIMEOUT_MS, killSignal: "SIGKILL", env: { ...process.env, AWS_PAGER: "", AWS_MAX_ATTEMPTS: "2" } }, (err, stdout, stderr) => {
          if (err) {
            // stderr from STS names the error code; it never holds the credentials.
            reject(new Error(`sts assume-role failed: ${String(stderr).trim().split("\n").at(-1) ?? err.message}`));
            return;
          }
          try {
            const c = (JSON.parse(stdout) as { Credentials: { AccessKeyId: string; SecretAccessKey: string; SessionToken: string; Expiration: string } }).Credentials;
            resolve({ accessKeyId: c.AccessKeyId, secretAccessKey: c.SecretAccessKey, sessionToken: c.SessionToken, expiration: c.Expiration });
          } catch {
            reject(new Error("sts assume-role returned output the broker could not read"));
          }
        });
      });
    },
  };
}
