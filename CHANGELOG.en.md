# Change log

[日本語](CHANGELOG.md) | English

The main changes by version. A version number is the same as `version` in `init.rb` and the repository's tag (`v1.0.0` and so on).

## 1.0.1 (2026-11-23)

The first version made public. Since 1.0.0, the README's Support section is taken out (1.0.0 was not made public).

## 1.0.0 (2026-11-23)

The first version.

- **Full-text search**: issues, notes, wiki pages, documents and the contents of attachments, searched with Apache Solr. Settings for Japanese (word forms, parts of words, spelling variants, synonyms) are included.
- **External sources**: documents in shared folders and the like are brought into Solr collections and listed with Redmine's data. An administrator allows a source for some projects, and each of them chooses what to search.
- **Permissions**: Redmine's permissions (private projects, private issues and notes, tracker and custom field restrictions) are followed, and results are checked again with Redmine's rules just before they are shown.
- **Running it**: the index updates itself with a regular crawl. The admin page has the status, rebuilding the index, the search log, synonyms and tuning the order.
- **Bundled Docker**: compose files by part, and example settings by combination (for trying, for adding to your Redmine, for Windows).
- **Versions**: Redmine 5.1 to 7.x, Apache Solr 9.x and 10.x ([requirements](README.en.md#requirements)).
