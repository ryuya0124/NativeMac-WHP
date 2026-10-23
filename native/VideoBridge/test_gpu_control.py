"""Capability lifetime checks for the pooled video target protocol."""
import unittest
from gpu_control import GpuControl


class Session(GpuControl):
    def __init__(self, answers):
        self.current=b'n'*16
        self.targets={b'p'*16}
        self.answers=iter(answers)
        self.calls=[]
        self.socket=None

    def operation(self, code, capability=bytes(16), argument=bytes(8), extra=b''):
        self.calls.append((code,capability,argument,extra))
        return next(self.answers)


class PooledTargets(unittest.TestCase):
    def test_reused_target_replaces_only_its_owned_previous_capability(self):
        session=Session([0])
        self.assertTrue(session.reuse(b'n'*16,b'p'*16))
        self.assertEqual(session.targets,set())
        self.assertEqual(session.current,b'n'*16)
        self.assertEqual(session.calls,[(b'R',b'n'*16,bytes(8),b'p'*16)])

    def test_expired_or_discarded_target_is_released_before_fallback(self):
        session=Session([1,0])
        self.assertFalse(session.reuse(b'n'*16,b'p'*16))
        self.assertEqual(session.targets,set())
        self.assertEqual(session.current,b'n'*16)
        self.assertEqual([call[0] for call in session.calls],[b'R',b'D'])

    def test_foreign_or_duplicate_capabilities_never_reach_the_endpoint(self):
        for fresh,previous in [(b'x'*16,b'p'*16),(b'n'*16,b'n'*16),(b'n'*16,b'x'*16)]:
            session=Session([])
            with self.assertRaises(RuntimeError):session.reuse(fresh,previous)
            self.assertEqual(session.calls,[])

    def test_completion_parks_only_a_successfully_copied_target(self):
        session=Session([2,0,0])
        session.copy(b'n'*16,b'n'*16,7,park=True)
        self.assertIsNone(session.current)
        self.assertIn(b'n'*16,session.targets)
        self.assertEqual([call[0] for call in session.calls],[b'Q',b'C',b'P'])
        session=Session([2,1])
        with self.assertRaises(RuntimeError):session.copy(b'n'*16,b'n'*16,7,park=True)
        self.assertEqual(session.current,b'n'*16)
        self.assertNotIn(b'n'*16,session.targets)
        self.assertEqual([call[0] for call in session.calls],[b'Q',b'C'])


if __name__=='__main__':unittest.main()
