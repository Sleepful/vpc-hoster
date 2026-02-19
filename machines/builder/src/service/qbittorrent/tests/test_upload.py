"""Tests for upload.py — B2 upload logic."""

import os
from pathlib import Path
from unittest.mock import MagicMock, call, patch

from upload import (
    link_to_import_dir,
    mark_uploaded,
    needs_linking,
    parse_categories,
    process_item,
    propagate_markers,
    rclone_check,
    rclone_copy,
    scan_completed_dir,
    scan_import_dir,
)


class TestRcloneCopy:
    @patch("upload.subprocess.run")
    def test_success(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)
        assert rclone_copy("/src/file.mkv", "b2:bucket/dest/") is True
        mock_run.assert_called_once()
        args = mock_run.call_args[0][0]
        assert args[0] == "rclone"
        assert args[1] == "copy"
        assert "--checksum" in args

    @patch("upload.subprocess.run")
    def test_failure(self, mock_run):
        mock_run.return_value = MagicMock(returncode=1)
        assert rclone_copy("/src/file.mkv", "b2:bucket/dest/") is False


class TestRcloneCheck:
    @patch("upload.subprocess.run")
    def test_exists(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)
        assert rclone_check("/src/file.mkv", "b2:bucket/dest/") is True

    @patch("upload.subprocess.run")
    def test_not_exists(self, mock_run):
        mock_run.return_value = MagicMock(returncode=1)
        assert rclone_check("/src/file.mkv", "b2:bucket/dest/") is False


class TestMarkUploaded:
    def test_creates_marker(self, tmp_path):
        item = tmp_path / "file.mkv"
        item.touch()
        assert mark_uploaded(item) is True
        assert (tmp_path / "file.mkv.uploaded").exists()

    def test_permission_error(self, tmp_path):
        item = tmp_path / "file.mkv"
        item.touch()
        with patch.object(Path, "touch", side_effect=PermissionError):
            assert mark_uploaded(item) is False


class TestProcessItem:
    @patch("upload.rclone_copy", return_value=True)
    @patch("upload.rclone_check", return_value=False)
    def test_simple_file(self, mock_check, mock_copy, tmp_path):
        item = tmp_path / "movie.mkv"
        item.write_bytes(b"data")
        extracted = tmp_path / "extracted"
        extracted.mkdir()

        result = process_item(item, "movies/", "b2:bucket", str(extracted))
        assert result is True
        assert Path(f"{item}.uploaded").exists()
        # rclone_copy called once for the original file
        assert mock_copy.call_count == 1

    @patch("upload.rclone_copy", return_value=True)
    @patch("upload.rclone_check", return_value=True)
    def test_already_on_b2(self, mock_check, mock_copy, tmp_path):
        item = tmp_path / "movie.mkv"
        item.write_bytes(b"data")
        extracted = tmp_path / "extracted"
        extracted.mkdir()

        result = process_item(item, "movies/", "b2:bucket", str(extracted))
        assert result is True
        assert Path(f"{item}.uploaded").exists()
        # Should not upload — already on B2
        mock_copy.assert_not_called()

    @patch("upload.subprocess.run")  # unar
    @patch("upload.rclone_copy", return_value=True)
    @patch("upload.rclone_check", return_value=False)
    def test_archive_file(self, mock_check, mock_copy, mock_run, tmp_path):
        mock_run.return_value = MagicMock(returncode=0)
        item = tmp_path / "release.zip"
        item.write_bytes(b"zipdata")
        extracted = tmp_path / "extracted"
        extracted.mkdir()

        result = process_item(item, "downloads/", "b2:bucket", str(extracted))
        assert result is True
        # unar called for extraction
        mock_run.assert_called_once()
        unar_args = mock_run.call_args[0][0]
        assert unar_args[0] == "unar"
        # rclone_copy called twice: once for extracted, once for original
        assert mock_copy.call_count == 2

    @patch("upload.subprocess.run")  # unar
    @patch("upload.rclone_copy", return_value=True)
    @patch("upload.rclone_check", return_value=False)
    def test_directory_with_archive(self, mock_check, mock_copy, mock_run, tmp_path):
        mock_run.return_value = MagicMock(returncode=0)
        item = tmp_path / "release-dir"
        item.mkdir()
        (item / "part1.rar").write_bytes(b"rardata")
        (item / "readme.txt").write_bytes(b"text")
        extracted = tmp_path / "extracted"
        extracted.mkdir()

        result = process_item(item, "downloads/", "b2:bucket", str(extracted))
        assert result is True
        # unar called for the .rar inside the directory
        assert mock_run.call_count == 1
        # rclone_copy: once for extracted, once for original directory
        assert mock_copy.call_count == 2

    @patch("upload.rclone_copy", return_value=False)
    @patch("upload.rclone_check", return_value=False)
    def test_upload_failure(self, mock_check, mock_copy, tmp_path):
        item = tmp_path / "movie.mkv"
        item.write_bytes(b"data")
        extracted = tmp_path / "extracted"
        extracted.mkdir()

        result = process_item(item, "movies/", "b2:bucket", str(extracted))
        assert result is False
        assert not Path(f"{item}.uploaded").exists()

    @patch("upload.rclone_copy", return_value=True)
    @patch("upload.rclone_check", return_value=False)
    def test_directory_destination(self, mock_check, mock_copy, tmp_path):
        """Directories get a named subfolder on B2."""
        item = tmp_path / "My Show"
        item.mkdir()
        (item / "episode.mkv").write_bytes(b"data")
        extracted = tmp_path / "extracted"
        extracted.mkdir()

        process_item(item, "tv/", "b2:bucket", str(extracted))
        # Check the dest passed to rclone_copy includes the dir name
        dest = mock_copy.call_args[0][1]
        assert dest == "b2:bucket/tv/My Show"

    @patch("upload.rclone_copy", return_value=True)
    @patch("upload.rclone_check", return_value=False)
    def test_file_destination(self, mock_check, mock_copy, tmp_path):
        """Files go directly into the base path (no name subfolder)."""
        item = tmp_path / "movie.mkv"
        item.write_bytes(b"data")
        extracted = tmp_path / "extracted"
        extracted.mkdir()

        process_item(item, "movies/", "b2:bucket", str(extracted))
        dest = mock_copy.call_args[0][1]
        assert dest == "b2:bucket/movies/"

    @patch("upload.rclone_copy", return_value=True)
    @patch("upload.rclone_check", return_value=False)
    def test_cleanup_extracted_dir(self, mock_check, mock_copy, tmp_path):
        """Extraction work dir is always cleaned up, even for non-archives."""
        item = tmp_path / "movie.mkv"
        item.write_bytes(b"data")
        extracted = tmp_path / "extracted"
        extracted.mkdir()

        process_item(item, "movies/", "b2:bucket", str(extracted))
        # Work dir (extracted/movie.mkv) should not exist after processing
        assert not (extracted / "movie.mkv").exists()


class TestScanImportDir:
    @patch("upload.process_item", return_value=True)
    def test_skips_uploaded(self, mock_process, tmp_path):
        (tmp_path / "episode.mkv").write_bytes(b"data")
        (tmp_path / "episode.mkv.uploaded").touch()
        (tmp_path / "new.mkv").write_bytes(b"data")

        scan_import_dir(tmp_path, "tv/", "b2:bucket", "/tmp/extracted")
        # Only new.mkv should be processed
        assert mock_process.call_count == 1
        assert mock_process.call_args[0][0].name == "new.mkv"

    @patch("upload.process_item", return_value=True)
    def test_skips_marker_files(self, mock_process, tmp_path):
        (tmp_path / "episode.mkv").write_bytes(b"data")
        (tmp_path / "episode.mkv.uploaded").touch()

        scan_import_dir(tmp_path, "tv/", "b2:bucket", "/tmp/extracted")
        mock_process.assert_not_called()

    @patch("upload.process_item", return_value=True)
    def test_recurses_into_directories(self, mock_process, tmp_path):
        show_dir = tmp_path / "Show Name"
        season_dir = show_dir / "Season 1"
        season_dir.mkdir(parents=True)
        (season_dir / "episode.mkv").write_bytes(b"data")

        scan_import_dir(tmp_path, "tv/", "b2:bucket", "/tmp/extracted")
        assert mock_process.call_count == 1
        # B2 base should include the full path hierarchy
        assert mock_process.call_args[0][1] == "tv/Show Name/Season 1/"

    @patch("upload.process_item", return_value=True)
    def test_nonexistent_directory(self, mock_process, tmp_path):
        scan_import_dir(tmp_path / "nonexistent", "tv/", "b2:bucket", "/tmp/extracted")
        mock_process.assert_not_called()


class TestScanCompletedDir:
    @patch("upload.process_item", return_value=True)
    def test_skips_category_dirs(self, mock_process, tmp_path):
        # Create a category subdir and a regular file
        tv_dir = tmp_path / "tv"
        tv_dir.mkdir()
        (tmp_path / "uncategorized.mkv").write_bytes(b"data")

        category_dirs = {str(tv_dir)}
        scan_completed_dir(
            tmp_path, "downloads/", "b2:bucket", "/tmp/extracted", category_dirs
        )
        assert mock_process.call_count == 1
        assert mock_process.call_args[0][0].name == "uncategorized.mkv"

    @patch("upload.process_item", return_value=True)
    def test_skips_uploaded(self, mock_process, tmp_path):
        (tmp_path / "file.mkv").write_bytes(b"data")
        (tmp_path / "file.mkv.uploaded").touch()

        scan_completed_dir(tmp_path, "downloads/", "b2:bucket", "/tmp/extracted", set())
        mock_process.assert_not_called()

    @patch("upload.process_item", return_value=True)
    def test_processes_uncategorized(self, mock_process, tmp_path):
        (tmp_path / "random-download").mkdir()
        (tmp_path / "file.mkv").write_bytes(b"data")

        scan_completed_dir(tmp_path, "downloads/", "b2:bucket", "/tmp/extracted", set())
        assert mock_process.call_count == 2


class TestNeedsLinking:
    def test_unlinked_file(self, tmp_path):
        """A file with nlink == 1 needs linking."""
        f = tmp_path / "movie.mkv"
        f.write_bytes(b"data")
        assert needs_linking(f) is True

    def test_linked_file(self, tmp_path):
        """A file with nlink > 1 (already hard linked) does not need linking."""
        f = tmp_path / "movie.mkv"
        f.write_bytes(b"data")
        link = tmp_path / "link.mkv"
        os.link(f, link)
        assert needs_linking(f) is False

    def test_unlinked_directory(self, tmp_path):
        """A directory where all files have nlink == 1 needs linking."""
        d = tmp_path / "torrent"
        d.mkdir()
        (d / "file1.mkv").write_bytes(b"data1")
        (d / "file2.mkv").write_bytes(b"data2")
        assert needs_linking(d) is True

    def test_directory_with_linked_file(self, tmp_path):
        """A directory with any nlink > 1 file does not need linking (arr-managed)."""
        d = tmp_path / "torrent"
        d.mkdir()
        f = d / "file.mkv"
        f.write_bytes(b"data")
        link = tmp_path / "linked.mkv"
        os.link(f, link)
        assert needs_linking(d) is False

    def test_empty_directory(self, tmp_path):
        """An empty directory needs linking (no files to check)."""
        d = tmp_path / "empty"
        d.mkdir()
        assert needs_linking(d) is True


class TestLinkToImportDir:
    def test_links_manual_file(self, tmp_path):
        """Manual file (nlink == 1) gets hard linked to import dir."""
        completed = tmp_path / "completed" / "movies"
        completed.mkdir(parents=True)
        import_dir = tmp_path / "arr" / "movies"
        import_dir.mkdir(parents=True)

        src = completed / "movie.mkv"
        src.write_bytes(b"data")

        link_to_import_dir(
            str(tmp_path / "completed"), str(tmp_path / "arr"), ["movies"]
        )

        dst = import_dir / "movie.mkv"
        assert dst.exists()
        assert os.stat(src).st_ino == os.stat(dst).st_ino

    def test_links_manual_directory(self, tmp_path):
        """Manual directory (all nlink == 1) gets hard linked preserving structure."""
        completed = tmp_path / "completed" / "movies"
        completed.mkdir(parents=True)
        import_dir = tmp_path / "arr" / "movies"
        import_dir.mkdir(parents=True)

        torrent = completed / "My.Movie.2024"
        torrent.mkdir()
        f1 = torrent / "movie.mkv"
        f1.write_bytes(b"video")
        sub = torrent / "Subs"
        sub.mkdir()
        f2 = sub / "english.srt"
        f2.write_bytes(b"subs")

        link_to_import_dir(
            str(tmp_path / "completed"), str(tmp_path / "arr"), ["movies"]
        )

        dst_movie = import_dir / "My.Movie.2024" / "movie.mkv"
        dst_subs = import_dir / "My.Movie.2024" / "Subs" / "english.srt"
        assert dst_movie.exists()
        assert dst_subs.exists()
        assert os.stat(f1).st_ino == os.stat(dst_movie).st_ino
        assert os.stat(f2).st_ino == os.stat(dst_subs).st_ino

    def test_skips_arr_managed(self, tmp_path):
        """Items with nlink > 1 (arr-managed) are not re-linked."""
        completed = tmp_path / "completed" / "movies"
        completed.mkdir(parents=True)
        import_dir = tmp_path / "arr" / "movies"
        import_dir.mkdir(parents=True)

        src = completed / "torrent.mkv"
        src.write_bytes(b"data")
        # Simulate Sonarr/Radarr hard link (different name)
        arr_link = import_dir / "Movie Name (2024).mkv"
        os.link(src, arr_link)

        link_to_import_dir(
            str(tmp_path / "completed"), str(tmp_path / "arr"), ["movies"]
        )

        # Should NOT create a second link with the torrent name
        assert not (import_dir / "torrent.mkv").exists()
        # Original arr link still exists
        assert arr_link.exists()

    def test_skips_already_uploaded(self, tmp_path):
        """Items with .uploaded marker are skipped."""
        completed = tmp_path / "completed" / "movies"
        completed.mkdir(parents=True)
        import_dir = tmp_path / "arr" / "movies"
        import_dir.mkdir(parents=True)

        src = completed / "movie.mkv"
        src.write_bytes(b"data")
        (completed / "movie.mkv.uploaded").touch()

        link_to_import_dir(
            str(tmp_path / "completed"), str(tmp_path / "arr"), ["movies"]
        )

        assert not (import_dir / "movie.mkv").exists()

    def test_skips_existing_destination(self, tmp_path):
        """Does not overwrite existing files in import dir."""
        completed = tmp_path / "completed" / "movies"
        completed.mkdir(parents=True)
        import_dir = tmp_path / "arr" / "movies"
        import_dir.mkdir(parents=True)

        src = completed / "movie.mkv"
        src.write_bytes(b"new data")
        # Pre-existing file in import dir with different content
        existing = import_dir / "movie.mkv"
        existing.write_bytes(b"old data")

        link_to_import_dir(
            str(tmp_path / "completed"), str(tmp_path / "arr"), ["movies"]
        )

        # Existing file should not be overwritten
        assert existing.read_bytes() == b"old data"

    def test_nonexistent_subdir(self, tmp_path):
        """No crash when completed subdir doesn't exist."""
        link_to_import_dir(
            str(tmp_path / "completed"), str(tmp_path / "arr"), ["movies"]
        )

    def test_multiple_subdirs(self, tmp_path):
        """Links items across multiple subdirs."""
        for subdir in ("tv", "movies"):
            (tmp_path / "completed" / subdir).mkdir(parents=True)
            (tmp_path / "arr" / subdir).mkdir(parents=True)

        (tmp_path / "completed" / "tv" / "show.mkv").write_bytes(b"tv")
        (tmp_path / "completed" / "movies" / "film.mkv").write_bytes(b"film")

        link_to_import_dir(
            str(tmp_path / "completed"), str(tmp_path / "arr"), ["movies", "tv"]
        )

        assert (tmp_path / "arr" / "tv" / "show.mkv").exists()
        assert (tmp_path / "arr" / "movies" / "film.mkv").exists()


class TestPropagateMarkers:
    def test_propagates_for_manual_item(self, tmp_path):
        """Marker propagated when import dir file (same inode) is marked uploaded."""
        completed = tmp_path / "completed" / "movies"
        completed.mkdir(parents=True)
        import_dir = tmp_path / "arr" / "movies"
        import_dir.mkdir(parents=True)

        src = completed / "movie.mkv"
        src.write_bytes(b"data")
        dst = import_dir / "movie.mkv"
        os.link(src, dst)
        # Mark import dir version as uploaded
        (import_dir / "movie.mkv.uploaded").touch()

        propagate_markers(
            str(tmp_path / "completed"), str(tmp_path / "arr"), ["movies"]
        )

        assert (completed / "movie.mkv.uploaded").exists()

    def test_propagates_for_arr_managed(self, tmp_path):
        """Marker propagated for arr items (different names, same inodes)."""
        completed = tmp_path / "completed" / "movies"
        completed.mkdir(parents=True)
        import_dir = tmp_path / "arr" / "movies" / "Movie Name (2024)"
        import_dir.mkdir(parents=True)

        src = completed / "torrent.x264.mkv"
        src.write_bytes(b"data")
        # Sonarr/Radarr hard link with a different name
        dst = import_dir / "Movie Name.mkv"
        os.link(src, dst)
        (import_dir / "Movie Name.mkv.uploaded").touch()

        propagate_markers(
            str(tmp_path / "completed"), str(tmp_path / "arr"), ["movies"]
        )

        assert (completed / "torrent.x264.mkv.uploaded").exists()

    def test_propagates_for_directory(self, tmp_path):
        """Marker propagated for directory items when all file inodes match."""
        completed = tmp_path / "completed" / "tv"
        completed.mkdir(parents=True)
        import_dir = tmp_path / "arr" / "tv"
        import_dir.mkdir(parents=True)

        torrent = completed / "show-torrent"
        torrent.mkdir()
        f1 = torrent / "ep1.mkv"
        f1.write_bytes(b"ep1")
        f2 = torrent / "ep2.mkv"
        f2.write_bytes(b"ep2")

        # Hard link both files to import dir
        dst_dir = import_dir / "show-torrent"
        dst_dir.mkdir()
        os.link(f1, dst_dir / "ep1.mkv")
        os.link(f2, dst_dir / "ep2.mkv")
        (dst_dir / "ep1.mkv.uploaded").touch()
        (dst_dir / "ep2.mkv.uploaded").touch()

        propagate_markers(str(tmp_path / "completed"), str(tmp_path / "arr"), ["tv"])

        assert (completed / "show-torrent.uploaded").exists()

    def test_no_propagation_if_not_all_uploaded(self, tmp_path):
        """No marker if some files in import dir are not yet uploaded."""
        completed = tmp_path / "completed" / "tv"
        completed.mkdir(parents=True)
        import_dir = tmp_path / "arr" / "tv"
        import_dir.mkdir(parents=True)

        torrent = completed / "show-torrent"
        torrent.mkdir()
        f1 = torrent / "ep1.mkv"
        f1.write_bytes(b"ep1")
        f2 = torrent / "ep2.mkv"
        f2.write_bytes(b"ep2")

        dst_dir = import_dir / "show-torrent"
        dst_dir.mkdir()
        os.link(f1, dst_dir / "ep1.mkv")
        os.link(f2, dst_dir / "ep2.mkv")
        # Only one of two files marked as uploaded
        (dst_dir / "ep1.mkv.uploaded").touch()

        propagate_markers(str(tmp_path / "completed"), str(tmp_path / "arr"), ["tv"])

        assert not (completed / "show-torrent.uploaded").exists()

    def test_skips_already_marked(self, tmp_path):
        """Items already marked as uploaded are skipped."""
        completed = tmp_path / "completed" / "movies"
        completed.mkdir(parents=True)
        import_dir = tmp_path / "arr" / "movies"
        import_dir.mkdir(parents=True)

        src = completed / "movie.mkv"
        src.write_bytes(b"data")
        (completed / "movie.mkv.uploaded").touch()

        propagate_markers(
            str(tmp_path / "completed"), str(tmp_path / "arr"), ["movies"]
        )

        # Should not crash or change anything
        assert (completed / "movie.mkv.uploaded").exists()

    def test_no_propagation_if_no_match(self, tmp_path):
        """No marker if file inodes don't exist in import dir."""
        completed = tmp_path / "completed" / "movies"
        completed.mkdir(parents=True)
        import_dir = tmp_path / "arr" / "movies"
        import_dir.mkdir(parents=True)

        src = completed / "movie.mkv"
        src.write_bytes(b"data")
        # No hard link in import dir — inode won't match anything

        propagate_markers(
            str(tmp_path / "completed"), str(tmp_path / "arr"), ["movies"]
        )

        assert not (completed / "movie.mkv.uploaded").exists()

    def test_nonexistent_dirs(self, tmp_path):
        """No crash when directories don't exist."""
        propagate_markers(
            str(tmp_path / "completed"), str(tmp_path / "arr"), ["movies"]
        )
