# Changelog

## 3.1.0

- Keep the window open after selecting **[3] Show status**, then display `Selection [1-5]:` again.
- Make `-Status` display status and enter the interactive action menu. This command now waits for input and should not be used in unattended jobs.
- Set `PackageVersion` to `3.1.0` in all three scripts. Replace all three files together when updating.
- Preserve immediate watcher startup after installation or update, both autostart methods, and the existing overlay workaround.

### Validation

The three scripts match the confirmed 3.1.0 ZIP package. Version consistency and the scoped status-menu changes were checked statically. A native Windows PowerShell 5.1 parse check and Windows integration tests were not run in the cloud environment.

## 3.0.0

Introduced the automatic watcher, tray controls, ChatGPT version tracking and per-user autostart manager alongside the one-shot overlay fix.

## 2.1

Previous manual-only overlay workaround.
