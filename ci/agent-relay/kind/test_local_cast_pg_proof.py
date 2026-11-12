from types import SimpleNamespace
import unittest

from local_cast_pg_proof import prove
from stack import StackError


class PostgresProofBoundaryTests(unittest.TestCase):
    def test_foreign_cluster_is_refused_before_credentials_or_resources(self):
        calls = []
        def owned():
            calls.append("owned")
            raise StackError("foreign cluster")
        stack = SimpleNamespace(docker=lambda **kw: calls.append("docker"), owned=owned)
        with self.assertRaisesRegex(StackError, "foreign cluster"):
            prove(stack)
        self.assertEqual(calls, ["docker", "owned"])


if __name__ == "__main__":
    unittest.main()
