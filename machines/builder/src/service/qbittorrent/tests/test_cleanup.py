"""Tests for cleanup.py — seeding lifecycle and cleanup."""

import json
import os
import time
import urllib.error
from pathlib import Path
from unittest.mock import MagicMock, patch

from cleanup import (
    cleanup_orphaned_markers,
    collect_inodes,
    fetch_torrents,
    find_torrent_by_path,
    parse_categories,
    prune_empty_dirs,
    remove_hardlinks,
    remove_torrent,
    scan_dir,
    should_keep_seeding,
)


class TestFetchTorrents:
    @patch("cleanup.urllib.request.urlopen")
    def test_success(self, mock_urlopen):
        data = [
            {
                "hash": "abc123",
                "content_path": "/completed/movie.mkv",
                "completion_on": 1000000,
                "uploaded": 5000000,
                "size": 1000000,
            }
        ]
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps(data).encode()
        mock_urlopen.return_value = mock_resp

        result = fetch_torrents("http://localhost:8080/api/v2")
        assert len(result) == 1
        assert result[0]["hash"] == "abc123"

    @patch("cleanup.urllib.request.urlopen")
    def test_api_error(self, mock_urlopen):
        mock_urlopen.side_effect = urllib.error.URLError("refused")
        assert fetch_torrents("http://localhost:8080/api/v2") is None

    @patch("cleanup.urllib.request.urlopen")
    def test_invalid_json(self, mock_urlopen):
        mock_resp = MagicMock()
        mock_resp.read.return_value = b"not json"
        mock_urlopen.return_value = mock_resp
        assert fetch_torrents("http://localhost:8080/api/v2") is None


class TestFindTorrentByPath:
    def test_match(self):
        torrents = [
            {"content_path": "/completed/a.mkv", "hash": "aaa"},
            {"content_path": "/completed/b.mkv", "hash": "bbb"},
        ]
        result = find_torrent_by_path(torrents, Path("/completed/b.mkv"))
        assert result["hash"] == "bbb"

    def test_no_match(self):
        torrents = [{"content_path": "/completed/a.mkv", "hash": "aaa"}]
        assert find_torrent_by_path(torrents, Path("/completed/missing.mkv")) is None

    def test_empty_list(self):
        assert find_torrent_by_path([], Path("/any/path")) is None


class TestRemoveTorrent:
    @patch("cleanup.urllib.request.urlopen")
    def test_success(self, mock_urlopen):
        mock_urlopen.return_value = MagicMock()
        assert remove_torrent("http://localhost:8080/api/v2", "abc123") is True
        req = mock_urlopen.call_args[0][0]
        assert b"deleteFiles=false" in req.data
        assert b"hashes=abc123" in req.data

    @patch("cleanup.urllib.request.urlopen")
    def test_failure(self, mock_urlopen):
        mock_urlopen.side_effect = urllib.error.URLError("error")
        assert remove_torrent("http://localhost:8080/api/v2", "abc123") is False


class TestCollectInodes:
    def test_single_file(self, tmp_path):
        f = tmp_path / "file.mkv"
        f.write_bytes(b"data")
        inodes = collect_inodes(f)
        assert len(inodes) == 1
        assert os.stat(f).st_ino in inodes

    def test_directory(self, tmp_path):
        d = tmp_path / "show"
        d.mkdir()
        (d / "ep1.mkv").write_bytes(b"data1")
        (d / "ep2.mkv").write_bytes(b"data2")
        inodes = collect_inodes(d)
        assert len(inodes) == 2

    def test_nonexistent(self, tmp_path):
        inodes = collect_inodes(tmp_path / "gone")
        assert len(inodes) == 0


class TestRemoveHardlinks:
    def test_removes_by_inode(self, tmp_path):
        """Hard links in import dirs sharing an inode with the source get deleted."""
        completed = tmp_path / "completed"
        completed.mkdir()
        import_dir = tmp_path / "import"
        import_dir.mkdir()

        # Create source file and hard link it into import dir
        source = completed / "movie.mkv"
        source.write_bytes(b"movie data")
        hardlink = import_dir / "Movie (2024).mkv"
        os.link(source, hardlink)

        # Verify they share an inode
        assert os.stat(source).st_ino == os.stat(hardlink).st_ino

        remove_hardlinks(source, [str(import_dir)])

        # Hard link should be removed
        assert not hardlink.exists()
        # Source should still exist (we only remove from import dirs)
        assert source.exists()

    def test_removes_directory_hardlinks(self, tmp_path):
        """Hard links from files inside a directory are found and removed."""
        completed = tmp_path / "completed"
        show_completed = completed / "show"
        show_completed.mkdir(parents=True)
        import_dir = tmp_path / "import" / "Show Name" / "Season 1"
        import_dir.mkdir(parents=True)

        source = show_completed / "ep1.mkv"
        source.write_bytes(b"episode data")
        hardlink = import_dir / "Show - S01E01.mkv"
        os.link(source, hardlink)

        remove_hardlinks(show_completed, [str(tmp_path / "import")])
        assert not hardlink.exists()

    def test_prunes_empty_dirs_after(self, tmp_path):
        """Empty directories are pruned after hardlink removal."""
        completed = tmp_path / "completed"
        completed.mkdir()
        import_dir = tmp_path / "import" / "Show" / "Season 1"
        import_dir.mkdir(parents=True)

        source = completed / "ep.mkv"
        source.write_bytes(b"data")
        os.link(source, import_dir / "ep.mkv")

        remove_hardlinks(source, [str(tmp_path / "import")])

        # Season 1/ and Show/ should be pruned (empty after deletion)
        assert not (tmp_path / "import" / "Show" / "Season 1").exists()
        assert not (tmp_path / "import" / "Show").exists()
        # import/ root still exists
        assert (tmp_path / "import").exists()

    def test_no_import_dirs(self, tmp_path):
        """No crash when import dirs don't exist."""
        f = tmp_path / "file.mkv"
        f.write_bytes(b"data")
        remove_hardlinks(f, ["/nonexistent/dir"])


class TestPruneEmptyDirs:
    def test_removes_nested_empty(self, tmp_path):
        (tmp_path / "a" / "b" / "c").mkdir(parents=True)
        prune_empty_dirs([str(tmp_path)])
        assert not (tmp_path / "a").exists()

    def test_keeps_nonempty(self, tmp_path):
        (tmp_path / "a" / "b").mkdir(parents=True)
        (tmp_path / "a" / "file.txt").write_bytes(b"data")
        prune_empty_dirs([str(tmp_path)])
        # a/ kept because it has file.txt; b/ removed because empty
        assert (tmp_path / "a").exists()
        assert not (tmp_path / "a" / "b").exists()


class TestShouldKeepSeeding:
    def test_too_young(self):
        now = 1_000_000
        torrent = {"completion_on": now - 86400, "uploaded": 999999}
        keep, reason = should_keep_seeding(
            torrent, now, min_age=10 * 86400, min_avg_rate=2048
        )
        assert keep is True
        assert "days left" in reason

    def test_active_upload(self):
        now = 1_000_000
        # Seeded for 15 days with 10 KB/s average
        age = 15 * 86400
        torrent = {
            "completion_on": now - age,
            "uploaded": 10240 * age,  # 10 KB/s * age
        }
        keep, reason = should_keep_seeding(
            torrent, now, min_age=10 * 86400, min_avg_rate=2048
        )
        assert keep is True
        assert "active" in reason

    def test_stale(self):
        now = 1_000_000
        age = 15 * 86400
        torrent = {
            "completion_on": now - age,
            "uploaded": 100,  # basically nothing
        }
        keep, reason = should_keep_seeding(
            torrent, now, min_age=10 * 86400, min_avg_rate=2048
        )
        assert keep is False
        assert reason is None

    def test_exactly_min_age(self):
        now = 1_000_000
        min_age = 10 * 86400
        torrent = {
            "completion_on": now - min_age,
            "uploaded": 0,
        }
        keep, _ = should_keep_seeding(torrent, now, min_age=min_age, min_avg_rate=2048)
        assert keep is False  # age == min_age, not less than

    def test_rate_at_threshold(self):
        now = 1_000_000
        age = 15 * 86400
        torrent = {
            "completion_on": now - age,
            "uploaded": 2048 * age,  # exactly at threshold
        }
        keep, _ = should_keep_seeding(
            torrent, now, min_age=10 * 86400, min_avg_rate=2048
        )
        assert keep is True  # >= threshold


class TestCleanupOrphanedMarkers:
    def test_removes_orphaned(self, tmp_path):
        # Marker with no corresponding file
        (tmp_path / "episode.mkv.uploaded").touch()
        cleanup_orphaned_markers([str(tmp_path)])
        assert not (tmp_path / "episode.mkv.uploaded").exists()

    def test_keeps_valid(self, tmp_path):
        (tmp_path / "episode.mkv").write_bytes(b"data")
        (tmp_path / "episode.mkv.uploaded").touch()
        cleanup_orphaned_markers([str(tmp_path)])
        assert (tmp_path / "episode.mkv.uploaded").exists()

    def test_nested_markers(self, tmp_path):
        show_dir = tmp_path / "Show" / "Season 1"
        show_dir.mkdir(parents=True)
        (show_dir / "ep.mkv.uploaded").touch()  # orphaned
        cleanup_orphaned_markers([str(tmp_path)])
        assert not (show_dir / "ep.mkv.uploaded").exists()


class TestScanDir:
    def _make_stats(self):
        return {"cleaned": 0, "seeding": 0, "skipped": 0}

    def test_skips_not_uploaded(self, tmp_path):
        (tmp_path / "file.mkv").write_bytes(b"data")
        stats = self._make_stats()
        scan_dir(
            tmp_path,
            [],
            "http://api",
            1_000_000,
            10 * 86400,
            2048,
            [],
            set(),
            stats,
        )
        assert stats["skipped"] == 1
        assert (tmp_path / "file.mkv").exists()  # not deleted

    def test_skips_category_dirs(self, tmp_path):
        tv_dir = tmp_path / "tv"
        tv_dir.mkdir()
        stats = self._make_stats()
        scan_dir(
            tmp_path,
            [],
            "http://api",
            1_000_000,
            10 * 86400,
            2048,
            [],
            {str(tv_dir)},
            stats,
        )
        assert stats == self._make_stats()  # Nothing processed
        assert tv_dir.exists()

    @patch("cleanup.remove_torrent", return_value=True)
    @patch("cleanup.remove_hardlinks")
    def test_cleans_orphan(self, mock_hardlinks, mock_remove, tmp_path):
        """Items not tracked by qBittorrent (orphans) are cleaned immediately."""
        f = tmp_path / "movie.mkv"
        f.write_bytes(b"data")
        (tmp_path / "movie.mkv.uploaded").touch()

        stats = self._make_stats()
        scan_dir(
            tmp_path,
            [],
            "http://api",
            1_000_000,
            10 * 86400,
            2048,
            ["/import"],
            set(),
            stats,
        )
        assert stats["cleaned"] == 1
        assert not f.exists()
        assert not (tmp_path / "movie.mkv.uploaded").exists()
        mock_hardlinks.assert_called_once()
        mock_remove.assert_not_called()  # Not tracked, no torrent to remove

    @patch("cleanup.remove_torrent", return_value=True)
    @patch("cleanup.remove_hardlinks")
    def test_removes_stale_torrent(self, mock_hardlinks, mock_remove, tmp_path):
        """Stale torrents (old + slow) are removed via API and cleaned up."""
        f = tmp_path / "movie.mkv"
        f.write_bytes(b"data")
        (tmp_path / "movie.mkv.uploaded").touch()

        now = 1_000_000
        torrents = [
            {
                "hash": "abc123",
                "content_path": str(f),
                "completion_on": now - 20 * 86400,  # 20 days ago
                "uploaded": 100,  # barely any upload
                "size": 1000000,
            }
        ]

        stats = self._make_stats()
        scan_dir(
            tmp_path,
            torrents,
            "http://api",
            now,
            10 * 86400,
            2048,
            ["/import"],
            set(),
            stats,
        )
        assert stats["cleaned"] == 1
        mock_remove.assert_called_once_with("http://api", "abc123")
        assert not f.exists()

    def test_keeps_seeding(self, tmp_path):
        """Torrents within seeding period are kept."""
        f = tmp_path / "movie.mkv"
        f.write_bytes(b"data")
        (tmp_path / "movie.mkv.uploaded").touch()

        now = 1_000_000
        torrents = [
            {
                "hash": "abc123",
                "content_path": str(f),
                "completion_on": now - 3 * 86400,  # 3 days ago (< 10)
                "uploaded": 5000000,
                "size": 1000000,
            }
        ]

        stats = self._make_stats()
        scan_dir(
            tmp_path,
            torrents,
            "http://api",
            now,
            10 * 86400,
            2048,
            [],
            set(),
            stats,
        )
        assert stats["seeding"] == 1
        assert f.exists()  # Not deleted

    def test_keeps_active_upload(self, tmp_path):
        """Torrents past min age but actively uploading are kept."""
        f = tmp_path / "movie.mkv"
        f.write_bytes(b"data")
        (tmp_path / "movie.mkv.uploaded").touch()

        now = 1_000_000
        age = 15 * 86400
        torrents = [
            {
                "hash": "abc123",
                "content_path": str(f),
                "completion_on": now - age,
                "uploaded": 10240 * age,  # 10 KB/s avg
                "size": 1000000,
            }
        ]

        stats = self._make_stats()
        scan_dir(
            tmp_path,
            torrents,
            "http://api",
            now,
            10 * 86400,
            2048,
            [],
            set(),
            stats,
        )
        assert stats["seeding"] == 1
        assert f.exists()

    @patch("cleanup.remove_torrent", return_value=True)
    @patch("cleanup.remove_hardlinks")
    def test_cleans_directory(self, mock_hardlinks, mock_remove, tmp_path):
        """Directory items are cleaned up with shutil.rmtree."""
        d = tmp_path / "show-dir"
        d.mkdir()
        (d / "ep1.mkv").write_bytes(b"data")
        (tmp_path / "show-dir.uploaded").touch()

        stats = self._make_stats()
        scan_dir(
            tmp_path,
            [],
            "http://api",
            1_000_000,
            10 * 86400,
            2048,
            ["/import"],
            set(),
            stats,
        )
        assert stats["cleaned"] == 1
        assert not d.exists()
