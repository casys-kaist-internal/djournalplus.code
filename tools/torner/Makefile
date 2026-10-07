# SPDX-License-Identifier: GPL-2.0
#
# Torner is built inside the guest as often as on the host, so it stays
# dependency-free: libc + pthreads, no configure step.

CC	?= gcc
CFLAGS	?= -O2 -g -Wall -Wextra -Wno-unused-parameter
CFLAGS	+= -std=gnu11 -D_GNU_SOURCE -Iinclude
LDFLAGS	+=
LDLIBS	+= -lpthread

PREFIX	?= /usr/local
BINDIR	?= $(PREFIX)/bin

SRCS	:= src/main.c src/common.c src/gen.c src/check.c src/loginv.c src/replay.c \
	   src/logidx.c src/atoms.c
OBJS	:= $(SRCS:.c=.o)
BIN	:= torner

.PHONY: all clean install test

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.c $(wildcard include/*.h)
	$(CC) $(CFLAGS) -c -o $@ $<

install: $(BIN)
	install -D -m0755 $(BIN) $(DESTDIR)$(BINDIR)/$(BIN)

test: $(BIN)
	./tests/selftest.sh
	./tests/loginv_test.sh
	./tests/replay_test.sh
	./tests/atoms_test.sh
	./tests/fuzz_test.sh

clean:
	rm -f $(OBJS) $(BIN)
