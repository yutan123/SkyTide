"""Validate the shipped worker lease and document SQL against SQLite."""
from pathlib import Path
import re
import sqlite3
import unittest
ROOT = Path(__file__).resolve().parents[1]
WORKERS = (ROOT / 'lib/plugin_worker_runner.dart').read_text()
DOCS = (ROOT / 'lib/plugin_database.dart').read_text()
def sql(source, prefix):
    return re.search(r"'(%s[^']*)'" % re.escape(prefix), source).group(1)
class EcosystemSQL(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        for query in re.findall(r"'(CREATE TABLE[^']+)'", WORKERS + DOCS):
            self.db.execute(query)
    def tearDown(self):
        self.db.close()
    def test_exclusive_lease_and_expiry_recovery(self):
        insert = sql(WORKERS, 'INSERT OR IGNORE')
        acquire = sql(WORKERS, 'UPDATE plugin_workers SET owner =')
        renew = sql(WORKERS, 'UPDATE plugin_workers SET lease_until =')
        self.db.execute(insert, ['p','sync'])
        self.assertEqual(self.db.execute(acquire, ['first',31000,'p','sync',1000,1000]).rowcount, 1)
        self.assertEqual(self.db.execute(acquire, ['second',31001,'p','sync',1001,1001]).rowcount, 0)
        self.assertEqual(self.db.execute(acquire, ['second',62000,'p','sync',32000,32000]).rowcount, 1)
        self.assertEqual(self.db.execute(renew, [70000,'p','sync','first',33000]).rowcount, 0)
        self.assertEqual(self.db.execute(renew, [70000,'p','sync','second',33000]).rowcount, 1)
    def test_stopped_host_cannot_release_a_replacement_lease(self):
        insert = sql(WORKERS, 'INSERT OR IGNORE')
        acquire = sql(WORKERS, 'UPDATE plugin_workers SET owner = ?')
        release = sql(WORKERS, 'UPDATE plugin_workers SET owner = NULL')
        self.db.execute(insert, ['p', 'sync'])
        self.db.execute(acquire, ['first', 31000, 'p', 'sync', 1000, 1000])
        self.db.execute(acquire, ['second', 62000, 'p', 'sync', 32000, 32000])
        self.assertEqual(self.db.execute(release, ['p', 'sync', 'first']).rowcount, 0)
        self.assertEqual(self.db.execute(release, ['p', 'sync', 'second']).rowcount, 1)
        self.assertEqual(self.db.execute('SELECT owner,lease_until FROM plugin_workers').fetchall(), [(None, 0)])
    def test_worker_scope_and_next_iteration(self):
        insert = sql(WORKERS, 'INSERT OR IGNORE')
        acquire = sql(WORKERS, 'UPDATE plugin_workers SET owner =')
        for plugin in ['p','q']:
            self.db.execute(insert, [plugin,'sync'])
            self.assertEqual(self.db.execute(acquire,['host',31000,plugin,'sync',1000,1000]).rowcount,1)
        self.db.execute('UPDATE plugin_workers SET owner=NULL,lease_until=0,next_at=5000 WHERE plugin_id=?',['p'])
        self.assertEqual(self.db.execute(acquire,['host',32000,'p','sync',4999,4999]).rowcount,0)
        self.assertEqual(self.db.execute(acquire,['host',35000,'p','sync',5000,5000]).rowcount,1)
    def test_document_isolation_literal_prefix_and_upsert(self):
        put = sql(DOCS, 'INSERT OR REPLACE INTO plugin_documents')
        for plugin, key, value in [('p','a%_1','"old"'),('q','a%_1','"private"'),('p','abc','"other"'),('p','a%_1','"new"')]:
            self.db.execute(put,[plugin,'items',key,value,None,100])
        query = 'SELECT key,value FROM plugin_documents WHERE plugin_id = ? AND collection = ? AND key > ? AND substr(key,1,?) = ? ORDER BY key ASC LIMIT ?'
        self.assertEqual(self.db.execute(query,['p','items','',3,'a%_',50]).fetchall(),[('a%_1','"new"')])
        self.assertEqual(self.db.execute(query,['q','items','',3,'a%_',50]).fetchall(),[('a%_1','"private"')])
    def test_migration_and_writes_rollback_together(self):
        put = sql(DOCS, 'INSERT OR REPLACE INTO plugin_documents')
        version = sql(DOCS, 'INSERT OR REPLACE INTO plugin_data_versions')
        try:
            with self.db:
                self.db.execute(version,['p',1])
                self.db.execute(put,['p','items','new','null',None,100])
                raise ValueError('late validation or quota failure')
        except ValueError:
            pass
        self.assertEqual(self.db.execute('SELECT * FROM plugin_documents').fetchall(),[])
        self.assertEqual(self.db.execute('SELECT * FROM plugin_data_versions').fetchall(),[])
if __name__ == '__main__':
    unittest.main()
