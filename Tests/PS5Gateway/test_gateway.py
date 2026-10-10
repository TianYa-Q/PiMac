import unittest
from gateway import FORWARD, REDIRECT, Session


class SessionTest(unittest.TestCase):
    def setUp(self):
        self.values = {FORWARD: '0', REDIRECT: '1'}
        self.writes = []
        self.session = Session(self.values.__getitem__, self.write)

    def write(self, key, value):
        self.writes.append((key, value))
        self.values[key] = value

    def test_start_and_restore_order(self):
        self.session.start()
        self.session.stop()
        self.assertEqual(self.writes, [(REDIRECT, '0'), (FORWARD, '1'),
                                      (FORWARD, '0'), (REDIRECT, '1')])
        self.session.stop()
        self.assertEqual(len(self.writes), 4)

    def test_refuses_existing_router(self):
        self.values[FORWARD] = '1'
        with self.assertRaises(RuntimeError):
            self.session.start()
        self.assertEqual(self.writes, [])

    def test_does_not_overwrite_external_change(self):
        self.session.start()
        self.values[FORWARD] = '0'
        self.session.stop()
        self.assertNotIn((FORWARD, '0'), self.writes)
        self.assertEqual(self.values[REDIRECT], '1')

    def test_partial_start_rolls_back(self):
        def fail_forward(key, value):
            if key == FORWARD and value == '1':
                raise RuntimeError('denied')
            self.write(key, value)
        self.session.write = fail_forward
        with self.assertRaisesRegex(RuntimeError, 'denied'):
            self.session.start()
        self.assertEqual(self.values, {FORWARD: '0', REDIRECT: '1'})

    def test_unchanged_redirect_is_not_owned(self):
        self.values[REDIRECT] = '0'
        self.session.start()
        self.session.stop()
        self.assertEqual(self.writes, [(FORWARD, '1'), (FORWARD, '0')])

    def test_failed_restore_can_retry(self):
        self.session.start()
        def fail(key, value):
            raise RuntimeError('denied')
        self.session.write = fail
        with self.assertRaises(RuntimeError):
            self.session.stop()
        self.session.write = self.write
        self.session.stop()
        self.assertEqual(self.values, {FORWARD: '0', REDIRECT: '1'})


if __name__ == '__main__':
    unittest.main()
