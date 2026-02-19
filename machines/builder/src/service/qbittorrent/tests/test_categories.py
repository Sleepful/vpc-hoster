"""Tests for categories.py — qBittorrent category registration."""

import json
import urllib.error
from http.client import HTTPResponse
from io import BytesIO
from unittest.mock import MagicMock, call, patch

from categories import create_or_update_category, parse_categories, wait_for_api


class TestParseCategories:
    def test_basic(self):
        assert parse_categories("tv-sonarr:tv,radarr:movies") == {
            "tv-sonarr": "tv",
            "radarr": "movies",
        }

    def test_single(self):
        assert parse_categories("tv-sonarr:tv") == {"tv-sonarr": "tv"}

    def test_whitespace(self):
        assert parse_categories(" tv-sonarr : tv , radarr : movies ") == {
            "tv-sonarr": "tv",
            "radarr": "movies",
        }

    def test_empty(self):
        assert parse_categories("") == {}

    def test_trailing_comma(self):
        assert parse_categories("tv-sonarr:tv,") == {"tv-sonarr": "tv"}


class TestWaitForApi:
    @patch("categories.urllib.request.urlopen")
    def test_immediate_success(self, mock_urlopen):
        mock_urlopen.return_value = MagicMock()
        assert wait_for_api("http://localhost:8080/api/v2", timeout=5) is True
        mock_urlopen.assert_called_once()

    @patch("categories.time.sleep")
    @patch("categories.urllib.request.urlopen")
    def test_success_after_retries(self, mock_urlopen, mock_sleep):
        mock_urlopen.side_effect = [
            urllib.error.URLError("refused"),
            urllib.error.URLError("refused"),
            MagicMock(),
        ]
        assert wait_for_api("http://localhost:8080/api/v2", timeout=5) is True
        assert mock_urlopen.call_count == 3
        assert mock_sleep.call_count == 2

    @patch("categories.time.sleep")
    @patch("categories.urllib.request.urlopen")
    def test_timeout(self, mock_urlopen, mock_sleep):
        mock_urlopen.side_effect = urllib.error.URLError("refused")
        assert wait_for_api("http://localhost:8080/api/v2", timeout=3) is False
        assert mock_urlopen.call_count == 3


class TestCreateOrUpdateCategory:
    @patch("categories.urllib.request.urlopen")
    def test_create_succeeds(self, mock_urlopen):
        mock_urlopen.return_value = MagicMock()
        result = create_or_update_category(
            "http://localhost:8080/api/v2",
            "tv-sonarr",
            "/completed/tv",
        )
        assert result is True
        # Should only call createCategory (first attempt succeeds)
        assert mock_urlopen.call_count == 1

    @patch("categories.urllib.request.urlopen")
    def test_create_fails_edit_succeeds(self, mock_urlopen):
        mock_urlopen.side_effect = [
            urllib.error.URLError("conflict"),  # createCategory fails
            MagicMock(),  # editCategory succeeds
        ]
        result = create_or_update_category(
            "http://localhost:8080/api/v2",
            "tv-sonarr",
            "/completed/tv",
        )
        assert result is True
        assert mock_urlopen.call_count == 2

    @patch("categories.urllib.request.urlopen")
    def test_both_fail(self, mock_urlopen):
        mock_urlopen.side_effect = urllib.error.URLError("error")
        result = create_or_update_category(
            "http://localhost:8080/api/v2",
            "tv-sonarr",
            "/completed/tv",
        )
        assert result is False
        assert mock_urlopen.call_count == 2

    @patch("categories.urllib.request.urlopen")
    def test_post_data(self, mock_urlopen):
        """Verify the POST request contains correct category data."""
        mock_urlopen.return_value = MagicMock()
        create_or_update_category(
            "http://localhost:8080/api/v2",
            "radarr",
            "/completed/movies",
        )
        req = mock_urlopen.call_args[0][0]
        assert req.method == "POST"
        assert b"category=radarr" in req.data
        assert b"savePath=%2Fcompleted%2Fmovies" in req.data
        assert "torrents/createCategory" in req.full_url
