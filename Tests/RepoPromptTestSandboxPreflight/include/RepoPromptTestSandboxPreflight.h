#ifndef REPOPROMPT_TEST_SANDBOX_PREFLIGHT_H
#define REPOPROMPT_TEST_SANDBOX_PREFLIGHT_H

#include <stdbool.h>
#include <stddef.h>

/// Test-only guard linked into RepoPromptTests and RepoPromptMCPCoreTests.
///
/// A constructor in this target runs when the test bundle is loaded, before any XCTest code. It
/// refuses to continue unless the process runs inside the isolated sandbox created by
/// `Scripts/ci_app_test_runner.py` (`./conductor test`), because an unsandboxed test process
/// resolves the user's real `~/Library/Application Support/RepoPrompt CE` storage.

/// Returns true when `sandbox_root` (containing the runner's marker file) holds `home` and
/// `fixed_user_home`, and does not contain `passwd_home`. On failure, writes a human-readable
/// reason into `reason`. On macOS, CoreFoundation/Foundation resolve the home directory (and
/// therefore Application Support) from `CFFIXED_USER_HOME`. TMPDIR is deliberately not required:
/// Foundation's temporary directory ignores it on macOS, and helper processes legitimately
/// override it; it never locates app storage.
bool rp_test_sandbox_validate(
    const char *sandbox_root,
    const char *home,
    const char *fixed_user_home,
    const char *passwd_home,
    char *reason,
    size_t reason_capacity
);

/// True when absolute `path` (which need not exist) is `root` or lies beneath it after resolving
/// symlinks of their existing prefixes (for example `/var` -> `/private/var`). False when a
/// component exists but cannot be resolved (for example a dangling symlink).
bool rp_test_sandbox_path_is_within(const char *path, const char *root);

/// Decides whether an inherited `GlobalCustomStorageURL` must be cleared at bundle load.
/// Returns false (leave it alone) only when `value`, after resolving symlinks in its existing
/// prefix, lies outside `passwd_home` and inside an existing marked runner sandbox: an ancestor
/// that holds the runner's marker file and does not contain `passwd_home` (normally a concurrently
/// running test). Everything else (real-home paths, paths outside every sandbox, sandboxes whose
/// marker is gone, dangling or unresolvable components, non-paths) is cleared.
bool rp_test_sandbox_should_clear_storage_override(const char *value, const char *passwd_home);

/// False when `argv` carries a `-GlobalCustomStorageURL <value>` launch argument (read by
/// UserDefaults' argument domain, which CFPreferences does not search) whose value would be
/// cleared by `rp_test_sandbox_should_clear_storage_override`, or has no value.
bool rp_test_sandbox_argument_override_is_safe(int argc, const char *const argv[], const char *passwd_home);

/// True once the bundle-load preflight accepted this process.
bool rp_test_sandbox_preflight_passed(void);

#endif
