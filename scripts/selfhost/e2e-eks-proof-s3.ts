// Pod Identity -> S3 round trip through the services image's own Locker
// adapter (src/shared/locker.ts), run in the alleyoop pod by e2e-eks-proof.sh.
// Writes, reads back, lists and deletes one object under e2e-eks-proof/.
const { lockerStore, credentialSource } = await import("/app/src/shared/locker.ts");
const { objectKey, readAll } = await import("/app/src/shared/vendor.ts");
const raw = lockerStore();
const key = `e2e-eks-proof/${Date.now()}.txt`;
const body = new TextEncoder().encode("eks pod identity probe");
const out = (r: string, c: string, d: string) => console.log(`EKS|${r}|${c}|${d}`);
let stored = false;
try {
  await raw.store.put(objectKey(key), body, { ifNoneMatch: true, contentType: "text/plain" });
  stored = true;
  const head = await raw.store.head(objectKey(key));
  const got = new TextDecoder().decode(await readAll(await raw.store.get(objectKey(key))));
  const listed = await raw.store.list(objectKey("e2e-eks-proof"));
  const listedKey = listed.items.some((i: any) => [i.key, i.name, i].includes(objectKey(key)));
  const ok = Boolean(head) && listedKey && got === "eks pod identity probe";
  out(ok ? "PASS" : "FAIL", "eks.s3_locker_roundtrip",
    `credentials=${credentialSource()} bucket=${process.env.LOCKER_BUCKET} key=${key} head=${head ? "found" : "none"} listed_key=${listedKey} read_back=${got === "eks pod identity probe"}`);
} catch (e) {
  out("FAIL", "eks.s3_locker_roundtrip", String((e as Error).message).slice(0, 200));
} finally {
  // Always remove the probe object; a store without delete fails the check.
  if (stored) {
    if (typeof (raw.store as any).delete !== "function") {
      out("FAIL", "eks.s3_locker_delete", "the Locker adapter has no delete");
    } else {
      try {
        await (raw.store as any).delete(objectKey(key));
        const gone = !(await raw.store.head(objectKey(key)));
        out(gone ? "PASS" : "FAIL", "eks.s3_locker_delete", `key=${key} head_after=${gone ? "none" : "found"}`);
      } catch (e) {
        out("FAIL", "eks.s3_locker_delete", String((e as Error).message).slice(0, 200));
      }
    }
  }
}
