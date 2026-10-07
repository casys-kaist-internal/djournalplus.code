/* SPDX-License-Identifier: GPL-2.0
 *
 * torner -- crash-atomicity test suite for tauJournal.
 */
#include "torner.h"

#include <stdio.h>
#include <string.h>

int torner_tear(int argc, char **argv);
int torner_loginv(int argc, char **argv);
int torner_replay(int argc, char **argv);
int torner_atoms(int argc, char **argv);

static void usage(void)
{
	fprintf(stderr,
"torner -- crash-atomicity test suite for tauJournal\n"
"\n"
"usage: torner <command> [options]\n"
"\n"
"  gen     synthetic workload: atomic-unit writes + progress log\n"
"  check   P1/P2 oracle over a recovered file\n"
"  tear    deliberately damage one unit (self-test for check)\n"
"  loginv  static ordering invariants over a dm-log-writes log (T2a)\n"
"  replay  build a crash state from a log subset (T2b)\n"
"  atoms   follow each application write through the log: did it reach the\n"
"          device in one piece, or in several?  (file-system agnostic)\n"
"\n"
"`torner <command> --help' for per-command options.\n");
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		usage();
		return 1;
	}
	if (!strcmp(argv[1], "gen"))
		return torner_gen(argc - 1, argv + 1);
	if (!strcmp(argv[1], "check"))
		return torner_check(argc - 1, argv + 1);
	if (!strcmp(argv[1], "tear"))
		return torner_tear(argc - 1, argv + 1);
	if (!strcmp(argv[1], "loginv"))
		return torner_loginv(argc - 1, argv + 1);
	if (!strcmp(argv[1], "replay"))
		return torner_replay(argc - 1, argv + 1);
	if (!strcmp(argv[1], "atoms"))
		return torner_atoms(argc - 1, argv + 1);
	if (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) {
		usage();
		return 0;
	}
	fprintf(stderr, "torner: unknown command '%s'\n", argv[1]);
	usage();
	return 1;
}
