#include "CTartExecIO.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

struct tart_exec_io {
  int fd;
  pthread_t thread;
  pthread_mutex_t mutex;
  pthread_cond_t ready;
  pthread_cond_t done;
  bool cancelled;
  bool pending;
  bool active;
  bool writing;
  void *buffer;
  size_t size;
  size_t transferred;
  int error;
};

// Also support callers whose descriptors were already nonblocking.
static int wait_ready(int fd, bool writing) {
  struct pollfd p = {.fd = fd, .events = writing ? POLLOUT : POLLIN};
  int result;
  do {
    result = poll(&p, 1, -1);
  } while (result < 0 && errno == EINTR);
  if (result < 0) return errno;
  return (p.revents & POLLNVAL) ? EBADF : 0;
}

static int transfer(tart_exec_io *io, size_t *transferred) {
  unsigned char *buffer = io->buffer;
  while (*transferred < io->size) {
    size_t remaining = io->size - *transferred;
    ssize_t count = io->writing ? write(io->fd, buffer + *transferred, remaining)
                                : read(io->fd, buffer, remaining);
    if (count >= 0) {
      *transferred += (size_t)count;
      // A partial pipe or terminal read is input, not EOF.
      if (!io->writing) return 0;
      if (count == 0) return EIO;
    } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
      int error = wait_ready(io->fd, io->writing);
      if (error) return error;
    } else if (errno != EINTR) {
      return errno;
    }
  }
  return 0;
}

// Called with the mutex held. The waiting caller owns the buffer until done.
static void complete(tart_exec_io *io, int error, size_t transferred) {
  io->error = error;
  io->transferred = transferred;
  io->active = false;
  io->pending = false;
  pthread_cond_signal(&io->done);
}

static void cancelled_transfer(void *context) {
  tart_exec_io *io = context;
  pthread_mutex_lock(&io->mutex);
  complete(io, ECANCELED, 0);
  pthread_mutex_unlock(&io->mutex);
}

static void *worker(void *context) {
  tart_exec_io *io = context;
  // Only the native syscall path is cancellable. Never cancel a Swift or
  // Dispatch worker, or leave a mutex locked across cancellation.
  pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);

  for (;;) {
    pthread_mutex_lock(&io->mutex);
    while (!io->pending && !io->cancelled) {
      pthread_cond_wait(&io->ready, &io->mutex);
    }
    if (io->cancelled) {
      if (io->pending) complete(io, ECANCELED, 0);
      pthread_mutex_unlock(&io->mutex);
      return NULL;
    }
    io->active = true;
    pthread_mutex_unlock(&io->mutex);

    int error;
    size_t transferred = 0;
    pthread_cleanup_push(cancelled_transfer, io);
    pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, NULL);
    error = transfer(io, &transferred);
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    pthread_cleanup_pop(0);

    pthread_mutex_lock(&io->mutex);
    complete(io, io->cancelled ? ECANCELED : error, transferred);
    pthread_mutex_unlock(&io->mutex);
  }
}

tart_exec_io *tart_exec_io_create(int fd, int *error) {
  tart_exec_io *io = calloc(1, sizeof(*io));
  if (!io) {
    *error = ENOMEM;
    return NULL;
  }
  io->fd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  if (io->fd < 0) {
    *error = errno;
    goto free_io;
  }
  if ((*error = pthread_mutex_init(&io->mutex, NULL))) goto close_fd;
  if ((*error = pthread_cond_init(&io->ready, NULL))) goto destroy_mutex;
  if ((*error = pthread_cond_init(&io->done, NULL))) goto destroy_ready;
  if ((*error = pthread_create(&io->thread, NULL, worker, io))) goto destroy_done;
  return io;

destroy_done:
  pthread_cond_destroy(&io->done);
destroy_ready:
  pthread_cond_destroy(&io->ready);
destroy_mutex:
  pthread_mutex_destroy(&io->mutex);
close_fd:
  close(io->fd);
free_io:
  free(io);
  return NULL;
}

static int request(tart_exec_io *io, void *buffer, size_t size, bool writing, size_t *transferred) {
  pthread_mutex_lock(&io->mutex);
  if (io->cancelled || io->pending) {
    int error = io->cancelled ? ECANCELED : EBUSY;
    pthread_mutex_unlock(&io->mutex);
    return error;
  }
  io->buffer = buffer;
  io->size = size;
  io->writing = writing;
  io->pending = true;
  pthread_cond_signal(&io->ready);
  while (io->pending) pthread_cond_wait(&io->done, &io->mutex);
  *transferred = io->transferred;
  int error = io->error;
  pthread_mutex_unlock(&io->mutex);
  return error;
}

int tart_exec_io_read(tart_exec_io *io, void *buffer, size_t size, size_t *transferred) {
  return request(io, buffer, size, false, transferred);
}

int tart_exec_io_write(tart_exec_io *io, const void *buffer, size_t size) {
  size_t transferred;
  return request(io, (void *)buffer, size, true, &transferred);
}

void tart_exec_io_cancel(tart_exec_io *io) {
  pthread_mutex_lock(&io->mutex);
  if (!io->cancelled) {
    io->cancelled = true;
    // The worker clears active before exiting, so the pthread is still live.
    if (io->active) pthread_cancel(io->thread);
    pthread_cond_signal(&io->ready);
  }
  pthread_mutex_unlock(&io->mutex);
}

void tart_exec_io_destroy(tart_exec_io *io) {
  tart_exec_io_cancel(io);
  pthread_join(io->thread, NULL);
  close(io->fd);
  pthread_cond_destroy(&io->done);
  pthread_cond_destroy(&io->ready);
  pthread_mutex_destroy(&io->mutex);
  free(io);
}
