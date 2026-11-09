"""Fresh-only storage image/official initializer contract; no Docker or DB."""
from copy import deepcopy
import hashlib,json,shutil,subprocess
from pathlib import Path
import unittest
from unittest.mock import patch
import yaml
from native_bootstrap import NativeBootstrapAdapter
from native_recipe import NativeRecipeError
import test_native_bootstrap as bootstrap

class NativeLocker(unittest.TestCase):
    image = bootstrap.NativeBootstrapTests.image
    render_fixture = bootstrap.NativeBootstrapTests.render_fixture
    observed_preflight = bootstrap.NativeBootstrapTests.observed_preflight
    fresh = bootstrap.NativeBootstrapTests.fresh
    setUp = bootstrap.NativeBootstrapTests.setUp
    tearDown = bootstrap.NativeBootstrapTests.tearDown

    def test_fresh_uses_reviewed_parent_server_and_only_qualified_official_client(self):
        self.fresh()
        values = next(json.loads(k["data"]) for a,k in self.stack.calls if a[:2] == ["helm","install"])
        self.assertEqual(values["image"], self.adapter._locker_image())
        for key in ["buckets","users","policies","svcaccts","customCommands"]:
            self.assertEqual(values[key], [])
        job = next(d for d in self.stack.objects_by_name.values() if d.get("kind") == "Job")
        self.assertEqual(job["spec"]["backoffLimit"],0)
        self.assertEqual(job["spec"]["activeDeadlineSeconds"],180)
        pod = job["spec"]["template"]["spec"]; main = pod["containers"][0]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertEqual(pod["restartPolicy"],"Never")
        self.assertEqual(main["image"],self.s["reference"])
        self.assertEqual(main["imagePullPolicy"],"Never")
        self.assertEqual(main["command"],["bun","src/locker/init.ts"])
        self.assertTrue(main["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(main["securityContext"]["capabilities"],{"drop":["ALL"]})
        env = {e["name"]:e for e in main["env"]}
        self.assertEqual(set(env),{"LOCKER_BUCKET","LOCKER_ENDPOINT","LOCKER_REGION","LOCKER_ACCESS_KEY_ID","LOCKER_SECRET_ACCESS_KEY"})
        self.assertEqual(env["LOCKER_SECRET_ACCESS_KEY"]["valueFrom"]["secretKeyRef"],{"name":self.s["secretRefs"]["locker"]["name"],"key":self.s["secretRefs"]["locker"]["key"]})
        self.assertEqual(pod["volumes"],[{"name":"tmp","emptyDir":{"medium":"Memory","sizeLimit":"32Mi"}}])
        self.assertLess(self.stack.effects.index(("qualified-node-import",None)),self.stack.effects.index(("create","Job")))
        self.assertNotIn("owner",json.dumps(pod))

    @unittest.skipUnless(shutil.which("helm"),"Helm required for actual dependency render")
    def test_actual_pinned_minio_chart_renders_no_mc_images_or_hooks(self):
        self.fresh(); values = next(json.loads(k["data"]) for a,k in self.stack.calls if a[:2] == ["helm","install"])
        root=Path(__file__).resolve().parents[3];chart=root/"charts/sessions-pipeline/charts/minio-5.4.0.tgz"
        self.assertEqual(hashlib.sha256(chart.read_bytes()).hexdigest(),NativeBootstrapAdapter.MINIO_CHART_SHA256)
        p=subprocess.run([shutil.which("helm"),"template","kind-locker",str(chart),"-n","agent-relay","-f","-"],input=yaml.safe_dump(values),text=True,capture_output=True,timeout=30)
        self.assertEqual(p.returncode,0,p.stderr);docs=[d for d in yaml.safe_load_all(p.stdout) if d]
        self.assertFalse(any(d["kind"]=="Job" or "helm.sh/hook" in d.get("metadata",{}).get("annotations",{}) for d in docs))
        images=[c["image"] for d in docs if d["kind"] in ["Deployment","StatefulSet"] for c in d["spec"]["template"]["spec"].get("containers",[])]
        self.assertEqual(images,[NativeBootstrapAdapter.MINIO_IMAGE_REPOSITORY+":"+NativeBootstrapAdapter.MINIO_IMAGE_TAG])
        self.assertNotIn("quay.io",p.stdout)

    def test_parent_pin_drift_refuses_instead_of_falling_back_to_upstream(self):
        for image in [{"repository":"quay.io/minio/minio","tag":"latest"},{"repository":"cgr.dev/chainguard/minio","tag":"latest"},{"repository":"unrelated/minio","tag":NativeBootstrapAdapter.MINIO_IMAGE_TAG}]:
            with self.subTest(image=image),patch("native_bootstrap.yaml.safe_load",return_value={"session-object-storage":{"image":image}}):
                with self.assertRaisesRegex(NativeRecipeError,"pinned_native_minio_image_changed"):
                    self.adapter._locker_image()
        self.assertEqual(self.stack.effects,[])

    def test_repeat_refuses_before_any_secret_install_import_or_bucket_operation(self):
        self.observed_preflight();self.adapter._inspected["mode"]="repeat"
        with self.assertRaisesRegex(NativeRecipeError,"retained"):
            self.adapter._prepare_locker(self.s)
        with self.assertRaisesRegex(NativeRecipeError,"retained"):
            self.adapter._initialize_locker_bucket(self.s)
        self.assertEqual(self.stack.effects,[])

    def refused_pod(self, mutate, code):
        original=self.adapter._get
        def get(resource,**kwargs):
            result=original(resource,**kwargs)
            if resource=="pods": mutate(result["items"][0])
            return result
        with patch.object(self.adapter,"_get",side_effect=get):
            with self.assertRaisesRegex(NativeRecipeError,code):self.fresh()
        before=list(self.stack.effects)
        with self.assertRaisesRegex(NativeRecipeError,"attempt_requires_review"):
            self.adapter._initialize_locker_bucket(self.s)
        self.assertEqual(self.stack.effects,before)

    def test_failed_official_client_never_counts_ready_or_silently_requeues(self):
        self.refused_pod(lambda p:p["status"]["containerStatuses"][0]["state"]["terminated"].update(exitCode=1),"initializer_exit_refused")
    def test_wrong_runtime_content_identity_refuses(self):
        self.refused_pod(lambda p:p["status"]["containerStatuses"][0].update(imageID="containerd://sha256:"+"f"*64),"initializer_image_changed")
    def test_foreign_job_pod_owner_refuses(self):
        self.refused_pod(lambda p:p["metadata"]["ownerReferences"][0].update(uid="foreign"),"one_completed_native_locker_pod_required")
    def test_changed_job_uid_after_wait_refuses(self):
        original=self.adapter._get
        def get(resource,**kwargs):
            value=original(resource,**kwargs)
            if resource.startswith("job/"):value["metadata"]["uid"]="foreign"
            return value
        with patch.object(self.adapter,"_get",side_effect=get),self.assertRaisesRegex(NativeRecipeError,"native_locker_job_not_complete"):self.fresh()

if __name__=="__main__":unittest.main()
