"""Exercise the task store's actual migration and lease recovery SQL in SQLite."""
from pathlib import Path
import re
import sqlite3
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'lib/plugin_task_store.dart').read_text()

def strings(expression):
    return ''.join(re.findall(r"'([^']*)'", expression))

class PluginTaskSqlTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.row_factory = sqlite3.Row
        create = re.search(r"db.execute\(\s*((?:'[^']*'\s*)+),", SOURCE)
        self.db.execute(strings(create.group(1)))
        self.db.execute("INSERT INTO plugin_tasks(plugin_id,id,bot_id,due_at,payload,state) VALUES ('p','legacy','b',1000,'null','pending')")
        migration = re.search(r"txn.execute\(\s*'([^']*ALTER TABLE[^']*)'\s*,?\s*\)", SOURCE)
        self.db.execute(migration.group(1))
        self.recovery = [strings(match) for match in re.findall(r"txn.rawUpdate\(\s*((?:'[^']*'\s*)+),", SOURCE)]

    def tearDown(self):
        self.db.close()

    def test_existing_tasks_survive_migration(self):
        row = self.db.execute('SELECT * FROM plugin_tasks').fetchone()
        self.assertEqual(row['interval_ms'], 0)
        self.assertEqual(row['payload'], 'null')
        self.assertEqual(row['state'], 'pending')

    def test_recovery_retries_then_advances_only_recurring_work(self):
        now = 181000
        self.db.execute('DELETE FROM plugin_tasks')
        cases = [('retry', 2, 0, 'running', 1000), ('once', 3, 0, 'running', 1000),
                 ('repeat', 3, 60000, 'running', 1000), ('cancelled', 3, 60000, 'cancelled', 1000),
                 ('leased', 3, 60000, 'running', now + 1000)]
        for name, attempts, interval, state, lease in cases:
            self.db.execute('INSERT INTO plugin_tasks(plugin_id,id,bot_id,due_at,payload,state,attempts,interval_ms,lease_until) VALUES (?,?,?,?,?,?,?,?,?)',
                            ('p', name, 'b', 1000, '{}', state, attempts, interval, lease))
        self.db.execute(self.recovery[0], ['pending', 'running', now])
        self.db.execute(self.recovery[1], ['failed', 'interrupted', 'running', now])
        self.db.execute(self.recovery[2], ['pending', 'interrupted', now, 'running', now])
        rows = {row['id']: row for row in self.db.execute('SELECT * FROM plugin_tasks')}
        self.assertEqual(rows['retry']['state'], 'pending')
        self.assertEqual(rows['retry']['attempts'], 2)
        self.assertEqual(rows['once']['state'], 'failed')
        self.assertEqual(rows['repeat']['state'], 'pending')
        self.assertEqual(rows['repeat']['due_at'], 241000)
        self.assertEqual(rows['repeat']['attempts'], 0)
        self.assertEqual(rows['repeat']['lease_until'], 0)
        self.assertEqual(rows['cancelled']['state'], 'cancelled')
        self.assertEqual(rows['leased']['state'], 'running')

if __name__ == '__main__':
    unittest.main()