#!/usr/bin/env python3
"""VectorDBBench's CLI, plus two options its pgvector commands do not expose.

VDB_INDEX_BEFORE_LOAD=1 makes the pgvector commands create the index on the
empty table and insert every row into it (create_index_before_load), instead
of loading the table and building the index afterwards (the CLI's only mode).
A build after the load writes the finished index once, as whole new pages
(log_newpage_range), so full_page_writes has nothing to do there; inserting
into an existing index rewrites old pages, which is where FPW costs.
pgvector's case config supports both; only the CLI lacks the switch.

VDB_CONN_PER_THREAD=1 lets --load-concurrency N load pgvector over N
connections. The pgvector client holds one connection and says it is not
thread-safe, so the insert runner clamps it to one worker; this gives each
worker thread its own copy and connection (copy_for_thread + init(), the
mechanism the client already has for that).

VDB_STREAM_DATASET, VDB_STREAM_STAGES and VDB_STREAM_CONC set the dataset,
search stages and search concurrencies of --case-type StreamingPerformanceCase
(the case takes them; the CLI only passes --streaming-insert-rate, so it
always streams Cohere 100K, searching at 50% and 80% with 5 and 10 clients):
    VDB_STREAM_DATASET="Large Cohere (768dim, 10M)" VDB_STREAM_STAGES="[0.1, 0.5, 0.9]"
    VDB_STREAM_CONC="[5]"

Everything else is VectorDBBench's own CLI, e.g.
    VDB_INDEX_BEFORE_LOAD=1 vdbbench.py pgvectorhnsw --case-type Performance768D1M ...
The submodule (bench/VectorDBBench) stays unmodified. The load runs in
spawned subprocesses, which re-import this file as __mp_main__, so the
patches below apply there too.
"""

import os
import threading

from vectordb_bench.backend.clients.pgvector import config as pgvector_config


def _index_before_load(cls):
    init = cls.__init__

    def __init__(self, **data):
        data.setdefault("create_index_before_load", True)
        data.setdefault("create_index_after_load", False)
        init(self, **data)

    cls.__init__ = __init__


if os.environ.get("VDB_INDEX_BEFORE_LOAD") == "1":
    # The config object is pickled into the runner's subprocess with these
    # fields set, so patching the parent is enough.
    _index_before_load(pgvector_config.PgVectorHNSWConfig)
    _index_before_load(pgvector_config.PgVectorIVFFlatConfig)

if os.environ.get("VDB_CONN_PER_THREAD") == "1":
    from vectordb_bench.backend.clients.pgvector.pgvector import PgVector
    from vectordb_bench.backend.runner.concurrent_runner import ConcurrentInsertRunner

    PgVector.thread_safe = True
    _thread = threading.local()

    def _get_thread_db(self):
        # One connection per worker thread, opened on its first batch and
        # closed when the load subprocess exits
        if getattr(_thread, "runner", None) is not self:
            db = self.db.copy_for_thread()
            ctx = db.init()
            ctx.__enter__()
            _thread.runner, _thread.db, _thread.ctx = self, db, ctx
        return _thread.db

    ConcurrentInsertRunner._get_thread_db = _get_thread_db

_STREAM_ENV = (("VDB_STREAM_DATASET", "dataset_with_size_type"),
               ("VDB_STREAM_STAGES", "search_stages"),
               ("VDB_STREAM_CONC", "concurrencies"))
if any(os.environ.get(env) for env, _ in _STREAM_ENV):
    from vectordb_bench.backend.clients.pgvector import cli as pgvector_cli
    from vectordb_bench.cli import cli as vdb_cli

    _get_custom_case_config = vdb_cli.get_custom_case_config

    def get_custom_case_config(parameters):
        config = _get_custom_case_config(parameters)
        if parameters["case_type"] == "StreamingPerformanceCase":
            for env, key in _STREAM_ENV:
                if os.environ.get(env):
                    config[key] = os.environ[env]
        return config

    # the pgvector commands call their own imported copy
    vdb_cli.get_custom_case_config = get_custom_case_config
    pgvector_cli.get_custom_case_config = get_custom_case_config

from vectordb_bench.cli.vectordbbench import cli  # noqa: E402

if __name__ == "__main__":
    cli()
