import os,re,csv,sys
ROOT=os.environ.get("TAUFS_BENCH_WS","/home/jhlee/djournalplus.code/bench/workspace")+"/results/sysbench"
LAB=re.compile(r"^(?P<db>postgres|mysql)_(?P<wl>oltp_[a-z_]+)_(?P<fs>.+?)_fpw_(?P<fpw>on|off)_(?P<sz>[st])(?P<n>\d+)_c(?P<c>\d+)_r(?P<r>\d+)$")
rows=[]
for dp,dn,fn in os.walk(ROOT):
    for f in fn:
        if not f.endswith(".log"): continue
        m=LAB.match(f[:-4])
        if not m: continue
        p=os.path.join(dp,f)
        try: txt=open(p,errors='ignore').read()
        except: continue
        t=re.search(r"transactions:\s+\d+\s+\(([\d.]+) per sec",txt)
        q=re.search(r"queries:\s+\d+\s+\(([\d.]+) per sec",txt)
        p99=re.search(r"99th percentile:\s+([\d.]+)",txt)
        avg=re.search(r"\bavg:\s+([\d.]+)",txt)
        d=m.groupdict(); d['run']=os.path.relpath(dp,ROOT)
        d['tps']=t.group(1) if t else ''
        d['qps']=q.group(1) if q else ''
        d['p99']=p99.group(1) if p99 else ''
        d['avg']=avg.group(1) if avg else ''
        # spec
        sp=p[:-4]+".spec"
        s={}
        if os.path.exists(sp):
            st=open(sp,errors='ignore').read()
            for k in ["innodb_buffer_pool_size","innodb_flush_method","innodb_flush_log_at_trx_commit","innodb_doublewrite","sync_binlog","innodb_redo_log_capacity","innodb_log_file_size","innodb_io_capacity","innodb_page_size"]:
                mm=re.search(r"^\|?\s*"+k+r"\s*\|?\s+(\S+)",st,re.M)
                if mm: s[k]=mm.group(1)
            for k in ["shared_buffers","max_wal_size","full_page_writes","synchronous_commit","wal_level","fsync","work_mem"]:
                mm=re.search(r"\n\s*"+k+r"\s*\n[- ]+\n\s*(\S+)",st)
                if mm: s[k]=mm.group(1)
        d.update(s)
        rows.append(d)
cols=["run","db","wl","fs","fpw","sz","n","c","r","tps","qps","avg","p99","shared_buffers","max_wal_size","full_page_writes","synchronous_commit","wal_level","fsync","innodb_buffer_pool_size","innodb_flush_method","innodb_flush_log_at_trx_commit","innodb_doublewrite","sync_binlog","innodb_redo_log_capacity","innodb_log_file_size","innodb_io_capacity","innodb_page_size"]
w=csv.DictWriter(open("/dev/stdout","w"),fieldnames=cols,extrasaction='ignore')
w.writeheader()
for r in sorted(rows,key=lambda x:(x['run'],x['db'],x['wl'],x['fs'],x['fpw'],int(x['c']))): w.writerow(r)
import sys; print(len(rows),"rows",file=sys.stderr)
