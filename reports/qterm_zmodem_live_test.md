# QTerm ZMODEM Live Test

- Target: `root@h1.niuwoai.com`
- Scope: direct SSH PTY/ZMODEM transport harness (`sz` ↔ remote `rz`, remote `sz` ↔ local `rz`)
- Result: **PASS**
- Started: `2026-08-10T18:03:52Z`
- Finished: `2026-08-10T18:03:54Z`

| Case | Result | Bytes | Local exit | Remote exit | SHA-256 matched |
|---|---:|---:|---:|---:|---:|
| rz_upload | PASS | 262144 | 0 | 0 | true |
| sz_download | PASS | 262144 | 0 | 0 | true |

## QTerm GUI observation

The same host was opened in the currently running QTerm app and an upload was initiated through the file picker. That attempt remained at “正在上传…” and did not create the remote file; the existing long-running QTerm process also reached sustained high CPU usage. The app was deliberately not terminated because it contained the user's active terminal tabs. Therefore this report proves the underlying live ZMODEM transport, while the GUI transfer path remains a reproducible issue that needs a clean-process diagnostic run.
