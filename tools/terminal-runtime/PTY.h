#ifndef MUSETERM_RUNTIME_PTY_H
#define MUSETERM_RUNTIME_PTY_H
#include <sys/types.h>
int museterm_pty_spawn(const char *executable, char *const argv[], char *const envp[],
                    const char *directory, int columns, int rows, pid_t *pid);
int museterm_pty_resize(int fd, int columns, int rows);
int museterm_pty_echo(int fd);
int museterm_pty_poll_exit(pid_t pid, int *status);
#endif
