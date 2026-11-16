/**
 * Credentials sealed to the requester: the "encrypted" delivery.
 *
 * The requester makes a one-time X25519 key pair on its own machine
 * (client.ts keygen) and puts the public key in its request. In relay mode
 * the request text, and so the key, comes from the Relay server, so the lead
 * can't substitute its own. The broker makes an ephemeral X25519 pair,
 * derives an AES-256-GCM key with HKDF-SHA256 over the shared secret (salt =
 * both public keys, info = the request id), and encrypts the
 * credential_process JSON. The reply carries the envelope (the ephemeral
 * public key, nonce, ciphertext and tag). The lead relays it but can't read
 * it; only the requester's private key opens it, and the request id is bound
 * in, so an envelope can't be passed off as another request's.
 */
import { createCipheriv, createDecipheriv, createPrivateKey, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes, type KeyObject } from "node:crypto";

export interface Envelope {
  v: 1;
  alg: "X25519-HKDF-SHA256-A256GCM";
  epk: string; // ephemeral public key, raw 32 bytes, base64
  iv: string; // 12 bytes, base64
  ct: string; // base64
  tag: string; // 16 bytes, base64
}

const SPKI_X25519_PREFIX = Buffer.from("302a300506032b656e032100", "hex");
const PKCS8_X25519_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");

/** A requester's public key: 32 raw bytes, base64 (what client.ts keygen prints). */
export function parsePublicKey(b64: string): KeyObject {
  // A string only: Buffer.from(array) would read an array as bytes, not base64.
  if (typeof b64 !== "string") throw new Error("publicKey must be a base64 string");
  const raw = Buffer.from(b64, "base64");
  if (raw.length !== 32 || raw.toString("base64") !== b64) throw new Error("publicKey must be a base64 32-byte X25519 key");
  return createPublicKey({ key: Buffer.concat([SPKI_X25519_PREFIX, raw]), format: "der", type: "spki" });
}

export const isPublicKey = (b64: unknown): boolean => {
  if (typeof b64 !== "string") return false;
  try {
    parsePublicKey(b64);
    return true;
  } catch {
    return false;
  }
};

function rawPublic(k: KeyObject): Buffer {
  return (k.export({ format: "der", type: "spki" }) as Buffer).subarray(SPKI_X25519_PREFIX.length);
}

function key(shared: Buffer, epk: Buffer, rpk: Buffer, requestId: string): Buffer {
  return Buffer.from(hkdfSync("sha256", shared, Buffer.concat([epk, rpk]), `aws-cred-broker/v1 ${requestId}`, 32));
}

export function seal(plaintext: string, recipientPublicKeyB64: string, requestId: string): Envelope {
  const rpk = parsePublicKey(recipientPublicKeyB64);
  const eph = generateKeyPairSync("x25519");
  const epkRaw = rawPublic(eph.publicKey);
  const shared = diffieHellman({ privateKey: eph.privateKey, publicKey: rpk });
  const iv = randomBytes(12);
  const c = createCipheriv("aes-256-gcm", key(shared, epkRaw, rawPublic(rpk), requestId), iv);
  c.setAAD(Buffer.from(requestId));
  const ct = Buffer.concat([c.update(plaintext, "utf8"), c.final()]);
  return { v: 1, alg: "X25519-HKDF-SHA256-A256GCM", epk: epkRaw.toString("base64"), iv: iv.toString("base64"), ct: ct.toString("base64"), tag: c.getAuthTag().toString("base64") };
}

export function open(env: Envelope, privateKeyRawB64: string, requestId: string): string {
  if (env.v !== 1 || env.alg !== "X25519-HKDF-SHA256-A256GCM") throw new Error("unknown envelope");
  const iv = Buffer.from(env.iv, "base64");
  const tag = Buffer.from(env.tag, "base64");
  // Exactly a 12-byte nonce and a full 16-byte tag: a truncated tag would weaken authentication.
  if (iv.length !== 12 || tag.length !== 16) throw new Error("envelope nonce must be 12 bytes and tag 16 bytes");
  const raw = Buffer.from(privateKeyRawB64, "base64");
  if (raw.length !== 32) throw new Error("private key must be 32 raw bytes, base64");
  const sk = createPrivateKey({ key: Buffer.concat([PKCS8_X25519_PREFIX, raw]), format: "der", type: "pkcs8" });
  const pk = createPublicKey(sk);
  const epkRaw = Buffer.from(env.epk, "base64");
  const epk = createPublicKey({ key: Buffer.concat([SPKI_X25519_PREFIX, epkRaw]), format: "der", type: "spki" });
  const shared = diffieHellman({ privateKey: sk, publicKey: epk });
  const d = createDecipheriv("aes-256-gcm", key(shared, epkRaw, rawPublic(pk), requestId), iv, { authTagLength: 16 });
  d.setAAD(Buffer.from(requestId));
  d.setAuthTag(tag);
  return Buffer.concat([d.update(Buffer.from(env.ct, "base64")), d.final()]).toString("utf8");
}

/** A fresh key pair for client.ts keygen: both raw 32 bytes, base64. */
export function newKeyPair(): { publicKey: string; privateKey: string } {
  const kp = generateKeyPairSync("x25519");
  const sk = (kp.privateKey.export({ format: "der", type: "pkcs8" }) as Buffer).subarray(PKCS8_X25519_PREFIX.length);
  return { publicKey: rawPublic(kp.publicKey).toString("base64"), privateKey: sk.toString("base64") };
}
