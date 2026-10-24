#include "PTY.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

/* argv/envp are prepared by the parent. After fork no Swift, Foundation,
 * allocation, logging or locks are used before exec. */
int qterm_pty_spawn(const char *executable, char *const argv[], char *const envp[],
                    const char *directory, int columns, int rows, pid_t *pid) {
    int errors[2];
    if (pipe(errors) < 0) return -1;
    if (fcntl(errors[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(errors[1], F_SETFD, FD_CLOEXEC) < 0) {
        int failure = errno; close(errors[0]); close(errors[1]); errno = failure; return -1;
    }
    long maximum_fd = sysconf(_SC_OPEN_MAX);
    if (maximum_fd < 0) maximum_fd = 10240;
    struct winsize size = {.ws_col = (unsigned short)columns, .ws_row = (unsigned short)rows};
    int master = -1;
    pid_t child = forkpty(&master, NULL, NULL, &size);
    if (child == 0) {
        close(errors[0]);
        for (int fd = 3; fd < maximum_fd; fd++) if (fd != errors[1]) close(fd);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        if (chdir(directory) == 0) execve(executable, argv, envp);
        int failure = errno;
        (void)write(errors[1], &failure, sizeof(failure));
        _exit(127);
    }
    int failure = errno;
    close(errors[1]);
    if (child < 0) { close(errors[0]); errno = failure; return -1; }
    struct pollfd pending = {.fd = errors[0], .events = POLLIN | POLLHUP};
    int ready;
    do { ready = poll(&pending, 1, 3000); } while (ready < 0 && errno == EINTR);
    ssize_t count = ready > 0 ? read(errors[0], &failure, sizeof(failure)) : -1;
    close(errors[0]);
    if (count != 0 || fcntl(master, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(master, F_SETFL, O_NONBLOCK) < 0) {
        if (count < 0) failure = ready == 0 ? ETIMEDOUT : errno;
        close(master);
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        errno = failure;
        return -1;
    }
    *pid = child;
    return master;
}

int qterm_pty_resize(int fd, int columns, int rows) {
    if (columns < 1 || rows < 1 || columns > 1000 || rows > 1000) { errno = EINVAL; return -1; }
    struct winsize size = {.ws_col = (unsigned short)columns, .ws_row = (unsigned short)rows};
    return ioctl(fd, TIOCSWINSZ, &size);
}

int qterm_pty_echo(int fd) {
    struct termios mode;
    if (tcgetattr(fd, &mode) < 0) return -1;
    return (mode.c_lflag & ECHO) != 0;
}

int qterm_pty_poll_exit(pid_t pid, int *status) {
    int raw = 0;
    pid_t result = waitpid(pid, &raw, WNOHANG);
    if (result <= 0) return (int)result;
    *status = WIFEXITED(raw) ? WEXITSTATUS(raw) : WIFSIGNALED(raw) ? 128 + WTERMSIG(raw) : -1;
    return 1;
}
