import json
import os
from pathlib import Path
import tempfile
import unittest
import source_mtimes


class SourceMtimesTests(unittest.TestCase):
    def test_only_identical_source_gets_its_compiled_timestamp_back(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, changed = root / 'same.rs', root / 'changed.rs'
            source.write_text('same'); changed.write_text('old')
            old, fresh = 1_000_000_000, 9_000_000_000
            for path in (source, changed): os.utime(path, ns=(old, old))
            cache = root / 'cache.json'
            self.assertEqual(source_mtimes.save(root, cache, ['same.rs', 'changed.rs']), 2)
            changed.write_text('new')
            for path in (source, changed): os.utime(path, ns=(fresh, fresh))
            self.assertEqual(source_mtimes.restore(root, cache), 1)
            self.assertEqual(source.stat().st_mtime_ns, old)
            self.assertEqual(changed.stat().st_mtime_ns, fresh)

    def test_cache_cannot_touch_files_outside_the_source_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'source'; source.mkdir()
            outside = root / 'outside.rs'; outside.write_text('private')
            before = outside.stat().st_mtime_ns
            (source / 'link.rs').symlink_to(outside)
            entry = {'sha256': source_mtimes.hashlib.sha256(outside.read_bytes()).hexdigest(), 'mtime_ns': 1}
            cache = source / 'cache.json'
            cache.write_text(json.dumps({'../outside.rs': entry, str(outside): entry, 'link.rs': entry}))
            self.assertEqual(source_mtimes.restore(source, cache), 0)
            self.assertEqual(outside.stat().st_mtime_ns, before)

    def test_missing_and_malformed_cache_are_optional(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); cache = root / 'cache.json'
            self.assertEqual(source_mtimes.restore(root, cache), 0)
            for value in ('invalid', '[]', '{"missing.rs": null}'):
                cache.write_text(value)
                self.assertEqual(source_mtimes.restore(root, cache), 0)


if __name__ == '__main__': unittest.main()
