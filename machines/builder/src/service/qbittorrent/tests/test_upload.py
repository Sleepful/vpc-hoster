"""Tests for upload.py — B2 upload logic."""

import os
from pathlib import Path
from unittest.mock import MagicMock, call, patch

from upload import (
    mark_uploaded,
    parse_categories,
    process_item,
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
