# Changelog

All notable changes to FeedBuddy are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-13

### Added
- Menu bar RSS/Atom reader, ported from the FeedWatch Chrome extension with all of its
  features: scheduled polling, unread count, feed auto-discovery, history backfill and
  on-demand older pages, feed icons with favicon fallback, per-feed view with filters,
  search, star, mark read/unread, mark all read, edit/delete feeds, notifications.
- OPML import and export.
- Start at login.

### Fixed (compared to FeedWatch)
- Feeds that ignore the paging parameter and serve everything in one file (e.g. Datadog
  release notes) no longer re-download the whole feed up to 10 times on every scroll to
  the bottom; they are recognized as having no older pages.

[1.0.0]: https://github.com/adriano-kaiser/feedbuddy/releases/tag/v1.0.0
