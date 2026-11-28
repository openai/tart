#ifndef CTART_EXEC_IO_H
#define CTART_EXEC_IO_H

#include <stddef.h>

typedef struct tart_exec_io tart_exec_io;

// Own a duplicate of fd without changing its open-file status flags.
tart_exec_io *tart_exec_io_create(int fd, int *error);

// These calls block on the private worker, not on Swift's cooperative executor.
// Return an errno value; a successful zero-length read means EOF.
int tart_exec_io_read(tart_exec_io *io, void *buffer, size_t size, size_t *transferred);
int tart_exec_io_write(tart_exec_io *io, const void *buffer, size_t size);

// Cancellation is permanent and can interrupt a blocked transfer.
void tart_exec_io_cancel(tart_exec_io *io);
// Call after all transfers have returned.
void tart_exec_io_destroy(tart_exec_io *io);

#endif
