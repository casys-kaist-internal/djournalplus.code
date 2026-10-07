# Build the tau test binaries. Run this inside the guest (or anywhere with the
# same libc) and put the result where the guest scripts expect it:
#
#   make && make install          # installs to ~/tautest
#   make install PREFIX=/opt/tau  # or somewhere else

CC      ?= gcc
CFLAGS  ?= -O2 -Wall
PREFIX  ?= $(HOME)/tautest

BINS := tauwrite tauwrite_nofsync taurace tauappend tauoverwrite tausync taucprace tautorn pgscan taushort tauabort

all: $(BINS)

tauwrite: src/tauwrite.c
	$(CC) $(CFLAGS) -o $@ $<

tauwrite_nofsync: src/tauwrite_nofsync.c
	$(CC) $(CFLAGS) -o $@ $<

taurace: src/taurace.c
	$(CC) $(CFLAGS) -pthread -o $@ $<

tauappend: src/tauappend.c
	$(CC) $(CFLAGS) -o $@ $<

tauoverwrite: src/tauoverwrite.c
	$(CC) $(CFLAGS) -o $@ $<

tausync: src/tausync.c
	$(CC) $(CFLAGS) -o $@ $<

taucprace: src/taucprace.c
	$(CC) $(CFLAGS) -o $@ $<

tautorn: src/tautorn.c
	$(CC) $(CFLAGS) -pthread -o $@ $<

pgscan: src/pgscan.c
	$(CC) $(CFLAGS) -o $@ $<

taushort: src/taushort.c
	$(CC) $(CFLAGS) -o $@ $<

tauabort: src/tauabort.c
	$(CC) $(CFLAGS) -pthread -o $@ $<

# PREFIX may be the build directory itself (that is what the host sync does),
# so skip anything that would copy a file onto itself.
install: all
	@mkdir -p $(PREFIX)
	@for b in $(BINS); do \
		src=$$(readlink -f $$b); dst=$$(readlink -f $(PREFIX)/$$b 2>/dev/null); \
		if [ "$$src" != "$$dst" ]; then cp $$b $(PREFIX)/; fi; \
	done

clean:
	rm -f $(BINS)

.PHONY: all install clean
