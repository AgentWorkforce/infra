import unittest
from analyze import epoch, peaks


class ResourceEvidence(unittest.TestCase):
    def test_cached_metrics_and_other_namespaces_do_not_inflate_a_step(self):
        def pod(namespace, time, value):
            return {"podRef": {"namespace": namespace}, "containers": [{"name": "gateway",
                "cpu": {"time": time, "usageNanoCores": value}, "memory": {"time": time, "workingSetBytes": value}}]}
        samples = [{"at": epoch("2000-01-01T00:02:00Z"), "nodeStats": {"pods": [
            pod("relaycast-bench", "2000-01-01T00:00:00Z", 99e9),
            pod("unrelated", "2000-01-01T00:01:10Z", 99e9),
            pod("relaycast-bench", "2000-01-01T00:01:10Z", 2e9)]}}]
        result = peaks(samples, epoch("2000-01-01T00:01:00Z"), epoch("2000-01-01T00:02:00Z"))
        self.assertEqual(result["gateway"]["cpuCores"], 2)
        self.assertAlmostEqual(result["gateway"]["workingSetMiB"], 2e9 / 1024**2)


if __name__ == "__main__":
    unittest.main()
