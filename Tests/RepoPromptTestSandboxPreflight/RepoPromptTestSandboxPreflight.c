#include "RepoPromptTestSandboxPreflight.h"

#include <CoreFoundation/CoreFoundation.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/// Must match `SANDBOX_MARKER_NAME` in `Scripts/ci_app_test_runner.py`.
static const char *const kSandboxMarkerName = ".issue944-test-sandbox";
static bool gPreflightPassed = false;

static void set_reason(char *reason, size_t capacity, const char *message, const char *detail) {
    if (reason == NULL || capacity == 0) {
        return;
    }
    snprintf(reason, capacity, "%s%s%s", message, detail ? ": " : "", detail ? detail : "");
}

/// Resolves the longest existing prefix of `path` with realpath(3) and re-appends the rest, so
/// paths that do not exist yet (or any more) still compare correctly. Rejects relative paths and
/// `.`/`..` components in the unresolved remainder.
static bool canonicalize(const char *path, char out[PATH_MAX]) {
    if (path == NULL || path[0] != '/') {
        return false;
    }
    char trimmed[PATH_MAX];
    if (strlcpy(trimmed, path, sizeof trimmed) >= sizeof trimmed) {
        return false;
    }
    size_t length = strlen(trimmed);
    while (length > 1 && trimmed[length - 1] == '/') {
        trimmed[--length] = '\0';
    }

    char probe[PATH_MAX];
    strlcpy(probe, trimmed, sizeof probe);
    for (;;) {
        char resolved[PATH_MAX];
        if (realpath(probe, resolved) != NULL) {
            const char *rest = trimmed + strlen(probe);
            if (strstr(rest, "/./") != NULL || strstr(rest, "/../") != NULL
                || strncmp(rest, "./", 2) == 0 || strncmp(rest, "../", 3) == 0
                || strcmp(rest, ".") == 0 || strcmp(rest, "..") == 0) {
                return false;
            }
            size_t rest_length = strlen(rest);
            if ((rest_length >= 2 && strcmp(rest + rest_length - 2, "/.") == 0)
                || (rest_length >= 3 && strcmp(rest + rest_length - 3, "/..") == 0)) {
                return false;
            }
            if (strcmp(resolved, "/") == 0 && rest[0] == '/') {
                resolved[0] = '\0';
            }
            if (strlcpy(out, resolved, PATH_MAX) >= PATH_MAX || strlcat(out, rest, PATH_MAX) >= PATH_MAX) {
                return false;
            }
            if (out[0] == '\0') {
                strlcpy(out, "/", PATH_MAX);
            }
            return true;
        }
        char *slash = strrchr(probe, '/');
        if (slash == NULL) {
            return false;
        }
        if (slash == probe) {
            if (probe[1] == '\0') {
                return false;
            }
            probe[1] = '\0';
        } else {
            *slash = '\0';
        }
    }
}

bool rp_test_sandbox_path_is_within(const char *path, const char *root) {
    char canonical_path[PATH_MAX];
    char canonical_root[PATH_MAX];
    if (!canonicalize(path, canonical_path) || !canonicalize(root, canonical_root)) {
        return false;
    }
    if (strcmp(canonical_root, "/") == 0) {
        return true;
    }
    size_t root_length = strlen(canonical_root);
    return strncmp(canonical_path, canonical_root, root_length) == 0
        && (canonical_path[root_length] == '\0' || canonical_path[root_length] == '/');
}

bool rp_test_sandbox_validate(
    const char *sandbox_root,
    const char *home,
    const char *fixed_user_home,
    const char *passwd_home,
    char *reason,
    size_t reason_capacity
) {
    if (sandbox_root == NULL || sandbox_root[0] == '\0') {
        set_reason(reason, reason_capacity, "REPOPROMPT_TEST_SANDBOX_ROOT is not set", NULL);
        return false;
    }
    char canonical_root[PATH_MAX];
    struct stat root_status;
    if (!canonicalize(sandbox_root, canonical_root) || stat(canonical_root, &root_status) != 0
        || !S_ISDIR(root_status.st_mode)) {
        set_reason(reason, reason_capacity, "REPOPROMPT_TEST_SANDBOX_ROOT is not an existing absolute directory", sandbox_root);
        return false;
    }
    if (strcmp(canonical_root, "/") == 0) {
        set_reason(reason, reason_capacity, "REPOPROMPT_TEST_SANDBOX_ROOT must not be the filesystem root", NULL);
        return false;
    }
    char marker[PATH_MAX];
    struct stat marker_status;
    if (snprintf(marker, sizeof marker, "%s/%s", canonical_root, kSandboxMarkerName) >= (int)sizeof marker
        || stat(marker, &marker_status) != 0 || !S_ISREG(marker_status.st_mode)) {
        set_reason(reason, reason_capacity, "sandbox marker file is missing", marker);
        return false;
    }
    if (passwd_home == NULL || passwd_home[0] == '\0') {
        set_reason(reason, reason_capacity, "cannot determine the user's real home directory", NULL);
        return false;
    }
    if (rp_test_sandbox_path_is_within(passwd_home, canonical_root)) {
        set_reason(reason, reason_capacity, "the sandbox contains the user's real home directory", passwd_home);
        return false;
    }
    const struct {
        const char *name;
        const char *value;
    } required[] = {
        {"HOME", home},
        {"CFFIXED_USER_HOME", fixed_user_home},
    };
    for (size_t index = 0; index < sizeof required / sizeof required[0]; index++) {
        if (required[index].value == NULL || !rp_test_sandbox_path_is_within(required[index].value, canonical_root)) {
            char detail[PATH_MAX + 64];
            snprintf(detail, sizeof detail, "%s=%s", required[index].name,
                     required[index].value ? required[index].value : "(unset)");
            set_reason(reason, reason_capacity, "environment path escapes the test sandbox", detail);
            return false;
        }
    }
    return true;
}

static bool path_exists(const char *path) {
    struct stat status;
    return path != NULL && stat(path, &status) == 0;
}

bool rp_test_sandbox_should_clear_storage_override(
    const char *value,
    const char *sandbox_root,
    const char *user_temp_root,
    const char *passwd_home
) {
    char canonical_value[PATH_MAX];
    if (!canonicalize(value, canonical_value)) {
        return true;
    }
    // Anything under the user's real home could be real data: never adopt it.
    if (passwd_home == NULL || rp_test_sandbox_path_is_within(canonical_value, passwd_home)) {
        return true;
    }

    // Test roots: the runner's sandbox parent (sandbox roots are `<parent>/<prefix-XXXX>/<digest>`)
    // and the per-user temporary directory where fixtures place their temp trees.
    bool under_test_root = false;
    char runner_parent[PATH_MAX];
    if (canonicalize(sandbox_root, runner_parent)) {
        for (int level = 0; level < 2; level++) {
            char *slash = strrchr(runner_parent, '/');
            if (slash == NULL || slash == runner_parent) {
                runner_parent[0] = '\0';
                break;
            }
            *slash = '\0';
        }
        if (runner_parent[0] != '\0' && !rp_test_sandbox_path_is_within(passwd_home, runner_parent)) {
            under_test_root = rp_test_sandbox_path_is_within(canonical_value, runner_parent);
        }
    }
    if (!under_test_root && user_temp_root != NULL && user_temp_root[0] != '\0'
        && !rp_test_sandbox_path_is_within(passwd_home, user_temp_root)) {
        under_test_root = rp_test_sandbox_path_is_within(canonical_value, user_temp_root);
    }
    if (!under_test_root) {
        return true;
    }

    // Live if the override directory or its parent exists (fixtures point the override at a
    // not-yet-created `Workspaces` child of a root they already created).
    char parent[PATH_MAX];
    strlcpy(parent, canonical_value, sizeof parent);
    char *slash = strrchr(parent, '/');
    if (slash != NULL && slash != parent) {
        *slash = '\0';
    }
    return !(path_exists(canonical_value) || path_exists(parent));
}

bool rp_test_sandbox_preflight_passed(void) {
    return gPreflightPassed;
}

/// Preferences are not redirected by HOME/CFFIXED_USER_HOME: every test process shares the real
/// `~/Library/Preferences` domain of its host tool. A fixture that crashed before restoring the
/// workspace storage override would otherwise hand the next process a dead root, which the
/// app-global default runtime captures once. Clear only overrides that could reach real data or
/// are dead; leave a live override that belongs to a concurrently running test alone.
static void clear_inherited_workspace_storage_override(const char *sandbox_root, const char *passwd_home) {
    CFStringRef key = CFSTR("GlobalCustomStorageURL");
    CFPropertyListRef value = CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication);
    if (value == NULL) {
        return;
    }
    bool should_clear = true;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        char path[PATH_MAX];
        char user_temp_root[PATH_MAX];
        size_t temp_length = confstr(_CS_DARWIN_USER_TEMP_DIR, user_temp_root, sizeof user_temp_root);
        if (CFStringGetFileSystemRepresentation((CFStringRef)value, path, sizeof path)) {
            should_clear = rp_test_sandbox_should_clear_storage_override(
                path,
                sandbox_root,
                temp_length > 0 && temp_length <= sizeof user_temp_root ? user_temp_root : NULL,
                passwd_home
            );
        }
    }
    CFRelease(value);
    if (!should_clear) {
        return;
    }
    CFPreferencesSetAppValue(key, NULL, kCFPreferencesCurrentApplication);
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    fprintf(stderr, "RepoPromptTests: cleared a stale or unsafe inherited GlobalCustomStorageURL.\n");
}

__attribute__((constructor))
static void rp_test_sandbox_preflight(void) {
    const char *sandbox_root = getenv("REPOPROMPT_TEST_SANDBOX_ROOT");
    const struct passwd *account = getpwuid(getuid());
    char reason[PATH_MAX + 256] = {0};
    if (!rp_test_sandbox_validate(
            sandbox_root,
            getenv("HOME"),
            getenv("CFFIXED_USER_HOME"),
            account ? account->pw_dir : NULL,
            reason,
            sizeof reason)) {
        fprintf(stderr,
                "\nRepoPromptTests refused to start: %s.\n"
                "Tests must never resolve the real RepoPrompt CE app storage. Run them through the\n"
                "isolated test sandbox instead:\n"
                "  ./conductor test [--filter <name>]      (or: make dev-test FILTER=<name>)\n"
                "  python3 Scripts/ci_app_test_runner.py --local [--filter <name>]\n\n",
                reason);
        fflush(stderr);
        _exit(78);
    }
    clear_inherited_workspace_storage_override(sandbox_root, account->pw_dir);
    gPreflightPassed = true;
}
