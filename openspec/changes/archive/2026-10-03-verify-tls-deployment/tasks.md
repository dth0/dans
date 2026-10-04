## 1. Disposable deployment rehearsal

- [x] 1.1 Add a runnable fixture test using the existing Compose deployment and private dependency networks.
- [x] 1.2 Exercise trusted TLS, secure sessions, allowed DNS writes, forgery denial, logout, and listener isolation; fix any confirmed deployment defect.
- [x] 1.3 Verify injected failure cleanup and containment of credentials and raw diagnostics.

## 2. Required verification and handoff

- [x] 2.1 Require the runtime rehearsal through the privacy-safe CI wrapper and document its scope and prerequisites.
- [x] 2.2 Run shell/configuration checks, the real Docker rehearsal, and strict OpenSpec validation.
- [x] 2.3 Privacy-screen every outgoing commit, run OCR on the exact diff, address confirmed findings, and inspect excluded files locally.

## 3. Blocking macOS CI repair

- [x] 3.1 Reproduce blocked watchdog cancellation and remove its process-lookup and signal-trap dependency while retaining escaped-reader rejection.
- [x] 3.2 Run stack behavior and host probes as independent macOS jobs, with shorter job/step limits and a focused cancellation regression.
- [x] 3.3 Verify native macOS and Linux behavior, privacy-screen the follow-up, and review the exact diff plus excluded files.
