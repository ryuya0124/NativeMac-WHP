// User-level timeout for temporary VM diagnostics. Only the child process group
// created by this invocation receives cancellation signals.
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t cancelled;
static void cancel(int signal_number) { cancelled = signal_number; }
static double seconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) _exit(125);
    return now.tv_sec + now.tv_nsec / 1e9;
}
static void pause_for(long nanoseconds) {
    struct timespec delay = {0, nanoseconds};
    while (nanosleep(&delay, &delay) && errno == EINTR) {}
}

int main(int argc, char **argv) {
    if (argc < 3) return 64;
    char *end;
    long timeout = strtol(argv[1], &end, 10);
    if (!argv[1][0] || *end || timeout < 1 || timeout > 600) return 64;
    signal(SIGINT, cancel);
    signal(SIGTERM, cancel);
    pid_t child = fork();
    if (child < 0) return 125;
    if (!child) {
        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        if (setpgid(0, 0)) _exit(125);
        execvp(argv[2], argv + 2);
        _exit(127);
    }
    // The child also establishes the group before exec, closing the setup race.
    if (setpgid(child, child) && errno != EACCES && errno != ESRCH) {
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
        return 125;
    }
    double deadline = seconds() + timeout;
    int status;
    for (;;) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) {
            if (WIFEXITED(status)) return WEXITSTATUS(status);
            return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 125;
        }
        if (result < 0 && errno != EINTR) return 125;
        if (cancelled || seconds() >= deadline) break;
        pause_for(100000000);
    }
    kill(-child, SIGTERM);
    // Do not reap the group leader during grace: its PID must not be reused.
    pause_for(900000000);
    kill(-child, SIGKILL);
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    fprintf(stderr, "Diagnostic child group cancelled (%s).\n", cancelled ? "signal" : "timeout");
    return cancelled ? 128 + cancelled : 124;
}
