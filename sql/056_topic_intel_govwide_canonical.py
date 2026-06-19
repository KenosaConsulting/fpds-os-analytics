#!/usr/bin/env python3
"""
056_topic_intel_govwide_canonical.py
Topic Intelligence Package — Phase 6: Govwide Canonical Topic Clustering

Clusters 9,313 merged topics across departments into canonical govwide topics
using embedding cosine similarity >= 0.85.

Steps:
  1. Extract merged topic labels + embeddings from DB
  2. Compute pairwise cosine similarity
  3. Agglomerative clustering at threshold 0.85
  4. Assign canonical IDs and representative labels
  5. Write canonical_topic_mapping table to DB
  6. Build mv_govwide_canonical MV

Run: python3 sql/056_topic_intel_govwide_canonical.py
Expected duration: 5-15 minutes (local compute + DB write)

Depends on: 044 (schema), 045 (catalog), 046 (agency profile)
Reference: Build Spec v1.1 §6
Date: 2026-06-18
"""

import subprocess
import sys
import time
import json

import numpy as np

def get_db_conn_string():
    """Get connection string using keychain."""
    pw = subprocess.check_output([
        "security", "find-generic-password",
        "-s", "openclaw-supabase-db-password",
        "-a", "kenosa-consulting", "-w"
    ]).decode().strip()
    return f"postgresql://postgres.tfrhforjvaafmqmxmtrt:{pw}@aws-1-us-east-2.pooler.supabase.com:5432/postgres"


def main():
    try:
        import psycopg2
        from psycopg2.extras import execute_values
    except ImportError:
        print("Installing psycopg2-binary...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "psycopg2-binary", "-q"])
        import psycopg2
        from psycopg2.extras import execute_values

    try:
        from sklearn.cluster import AgglomerativeClustering
    except ImportError:
        print("Installing scikit-learn...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "scikit-learn", "-q"])
        from sklearn.cluster import AgglomerativeClustering

    conn_str = get_db_conn_string()
    conn = psycopg2.connect(conn_str)
    conn.autocommit = False
    cur = conn.cursor()

    # ----------------------------------------------------------------
    # Step 1: Extract merged topic labels + embeddings
    # ----------------------------------------------------------------
    print("Step 1: Extracting merged topic embeddings...")
    cur.execute("""
        SELECT tl.model_id, tl.topic_id, tl.label, tl.description,
               substring(tl.model_id FROM 'v2\\.1-([^-]+)-') AS department_code,
               te.embedding_vec::text
        FROM v2.topic_labels tl
        JOIN v2.topic_embeddings te
          ON tl.model_id = te.model_id AND tl.topic_id = te.topic_id
        WHERE tl.corpus_type = 'merged'
        ORDER BY tl.model_id, tl.topic_id
    """)
    rows = cur.fetchall()
    print(f"  Fetched {len(rows)} merged topics with embeddings")

    model_ids = []
    topic_ids = []
    labels = []
    descriptions = []
    dept_codes = []
    embeddings = []

    for row in rows:
        model_ids.append(row[0])
        topic_ids.append(row[1])
        labels.append(row[2])
        descriptions.append(row[3])
        dept_codes.append(row[4])
        # Parse vector string: '[0.1,0.2,...]'
        vec_str = row[5].strip('[]')
        vec = np.fromstring(vec_str, sep=',', dtype=np.float32)
        embeddings.append(vec)

    X = np.vstack(embeddings)
    n_topics = X.shape[0]
    print(f"  Embedding matrix: {X.shape} ({X.nbytes / 1e6:.1f} MB)")

    # ----------------------------------------------------------------
    # Step 2: Normalize and compute cosine distance
    # ----------------------------------------------------------------
    print("Step 2: Normalizing embeddings...")
    norms = np.linalg.norm(X, axis=1, keepdims=True)
    norms[norms == 0] = 1  # avoid div by zero
    X_norm = X / norms

    # AgglomerativeClustering uses distance, not similarity
    # cosine_distance = 1 - cosine_similarity
    # threshold 0.85 similarity = 0.15 distance
    SIMILARITY_THRESHOLD = 0.85
    DISTANCE_THRESHOLD = 1.0 - SIMILARITY_THRESHOLD
    print(f"  Similarity threshold: {SIMILARITY_THRESHOLD}")
    print(f"  Distance threshold: {DISTANCE_THRESHOLD}")

    # ----------------------------------------------------------------
    # Step 3: Agglomerative clustering
    # ----------------------------------------------------------------
    print("Step 3: Clustering...")
    t0 = time.time()
    clustering = AgglomerativeClustering(
        n_clusters=None,
        distance_threshold=DISTANCE_THRESHOLD,
        metric='cosine',
        linkage='average'
    )
    cluster_labels = clustering.fit_predict(X_norm)
    n_clusters = len(set(cluster_labels))
    elapsed = time.time() - t0
    print(f"  {n_clusters} canonical topics from {n_topics} merged topics ({elapsed:.1f}s)")

    # ----------------------------------------------------------------
    # Step 4: Assign canonical labels
    # ----------------------------------------------------------------
    print("Step 4: Assigning canonical labels...")
    canonical_topics = {}
    for i, cl in enumerate(cluster_labels):
        if cl not in canonical_topics:
            canonical_topics[cl] = []
        canonical_topics[cl].append(i)

    # For each cluster: pick the member with the highest embedding norm
    # as representative (typically the most "central" topic)
    mapping_rows = []
    canonical_id = 0
    for cl in sorted(canonical_topics.keys()):
        members = canonical_topics[cl]
        dept_set = set(dept_codes[m] for m in members)

        # Representative = member closest to cluster centroid
        centroid = X_norm[members].mean(axis=0)
        centroid_norm = centroid / (np.linalg.norm(centroid) + 1e-10)
        sims = X_norm[members] @ centroid_norm
        rep_idx = members[np.argmax(sims)]

        canonical_label = labels[rep_idx]
        canonical_desc = descriptions[rep_idx]
        canonical_id += 1

        for m in members:
            sim_to_centroid = float(X_norm[m] @ centroid_norm)
            mapping_rows.append((
                canonical_id,
                canonical_label,
                canonical_desc,
                model_ids[m],
                topic_ids[m],
                labels[m],
                dept_codes[m],
                round(sim_to_centroid, 6)
            ))

    print(f"  {len(mapping_rows)} mapping rows for {canonical_id} canonical topics")
    print(f"  Topics per cluster: min={min(len(v) for v in canonical_topics.values())}, "
          f"max={max(len(v) for v in canonical_topics.values())}, "
          f"median={sorted(len(v) for v in canonical_topics.values())[len(canonical_topics)//2]}")

    # Multi-department canonical topics
    multi_dept = sum(1 for cl in canonical_topics.values()
                     if len(set(dept_codes[m] for m in cl)) > 1)
    print(f"  Multi-department canonical topics: {multi_dept}")

    # ----------------------------------------------------------------
    # Step 5: Write to DB
    # ----------------------------------------------------------------
    print("Step 5: Writing canonical_topic_mapping to DB...")
    cur.execute("DROP TABLE IF EXISTS topic_intelligence.canonical_topic_mapping CASCADE")
    cur.execute("""
        CREATE TABLE topic_intelligence.canonical_topic_mapping (
            canonical_topic_id     integer NOT NULL,
            canonical_label        text NOT NULL,
            canonical_description  text,
            member_model_id        text NOT NULL,
            member_topic_id        integer NOT NULL,
            member_label           text,
            member_department_code text,
            similarity_to_centroid numeric(8,6)
        )
    """)

    execute_values(
        cur,
        """INSERT INTO topic_intelligence.canonical_topic_mapping
           (canonical_topic_id, canonical_label, canonical_description,
            member_model_id, member_topic_id, member_label,
            member_department_code, similarity_to_centroid)
           VALUES %s""",
        mapping_rows,
        page_size=1000
    )

    cur.execute("""
        CREATE INDEX idx_canonical_mapping_canonical_id
          ON topic_intelligence.canonical_topic_mapping (canonical_topic_id)
    """)
    cur.execute("""
        CREATE INDEX idx_canonical_mapping_member
          ON topic_intelligence.canonical_topic_mapping (member_model_id, member_topic_id)
    """)
    cur.execute("""
        GRANT SELECT ON topic_intelligence.canonical_topic_mapping
          TO fpds_analytics_api_readonly
    """)

    conn.commit()
    print(f"  Written {len(mapping_rows)} rows")

    # ----------------------------------------------------------------
    # Step 6: Build mv_govwide_canonical
    # ----------------------------------------------------------------
    print("Step 6: Building mv_govwide_canonical...")
    cur.execute("SET statement_timeout = 0")
    cur.execute("DROP MATERIALIZED VIEW IF EXISTS topic_intelligence.mv_govwide_canonical CASCADE")
    cur.execute("""
        CREATE MATERIALIZED VIEW topic_intelligence.mv_govwide_canonical AS
        SELECT
          ctm.canonical_topic_id,
          ctm.canonical_label,
          ctm.canonical_description,
          count(DISTINCT ctm.member_department_code) AS department_count,
          array_agg(DISTINCT ctm.member_department_code ORDER BY ctm.member_department_code) AS departments,
          sum(ac.assignment_count) AS total_assignments_govwide,
          mode() WITHIN GROUP (ORDER BY tl.naics_alignment) AS naics_alignment
        FROM topic_intelligence.canonical_topic_mapping ctm
        JOIN v2.topic_labels tl
          ON ctm.member_model_id = tl.model_id
          AND ctm.member_topic_id = tl.topic_id
        LEFT JOIN topic_intelligence.mv_agency_profile ac
          ON ctm.member_model_id = ac.model_id
          AND ctm.member_topic_id = ac.topic_id
        GROUP BY
          ctm.canonical_topic_id,
          ctm.canonical_label,
          ctm.canonical_description
    """)
    cur.execute("""
        CREATE UNIQUE INDEX idx_govwide_canonical_id
          ON topic_intelligence.mv_govwide_canonical (canonical_topic_id)
    """)
    cur.execute("""
        CREATE INDEX idx_govwide_canonical_dept_count
          ON topic_intelligence.mv_govwide_canonical (department_count DESC)
    """)
    cur.execute("""
        CREATE INDEX idx_govwide_canonical_assignments
          ON topic_intelligence.mv_govwide_canonical (total_assignments_govwide DESC NULLS LAST)
    """)
    cur.execute("""
        GRANT SELECT ON topic_intelligence.mv_govwide_canonical
          TO fpds_analytics_api_readonly
    """)
    conn.commit()

    # Add facade view
    cur.execute("""
        CREATE OR REPLACE VIEW analytics_api.topics_govwide_canonical AS
          SELECT * FROM topic_intelligence.mv_govwide_canonical
    """)
    cur.execute("""
        GRANT SELECT ON analytics_api.topics_govwide_canonical
          TO fpds_analytics_api_readonly
    """)
    conn.commit()

    # ----------------------------------------------------------------
    # Verify
    # ----------------------------------------------------------------
    print("\n=== Verification ===")
    cur.execute("""
        SELECT count(*) AS total,
               count(DISTINCT canonical_topic_id) AS canonical_topics,
               min(department_count) AS min_depts,
               max(department_count) AS max_depts,
               avg(department_count)::numeric(4,1) AS avg_depts
        FROM topic_intelligence.mv_govwide_canonical
    """)
    row = cur.fetchone()
    print(f"  Canonical topics: {row[1]}")
    print(f"  Department coverage: min={row[2]}, max={row[3]}, avg={row[4]}")

    cur.execute("""
        SELECT canonical_topic_id, canonical_label, department_count,
               total_assignments_govwide, naics_alignment
        FROM topic_intelligence.mv_govwide_canonical
        ORDER BY department_count DESC, total_assignments_govwide DESC NULLS LAST
        LIMIT 10
    """)
    print("\n  Top 10 canonical topics by cross-department prevalence:")
    print(f"  {'ID':>5} | {'Depts':>5} | {'Assignments':>12} | Label")
    print(f"  {'-'*5}-+-{'-'*5}-+-{'-'*12}-+-{'-'*50}")
    for r in cur.fetchall():
        assigns = r[3] if r[3] else 0
        print(f"  {r[0]:>5} | {r[2]:>5} | {assigns:>12,} | {r[1][:50] if r[1] else 'N/A'}")

    cur.close()
    conn.close()
    print("\n=== 056: COMPLETE ===")


if __name__ == "__main__":
    main()
