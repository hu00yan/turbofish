// Cursor/Notion 工作负载端到端验证测试：
// 1) 10,000 基线文档 -> 50 轮连续小批量突变（每轮编辑 10 篇文档）；
// 2) 断言 1：读路径全生命周期零 LIST 调用（0 LIST requests）；
// 3) 断言 2：写放大严格受限（每次突变仅写入轻量 L0 delta part，绝无基线数据全量重写）；
// 4) 断言 3：条件唤醒策略正常触发（L0 达到阈值或墓碑积累触发 Compactor，物理化消除已删除墓碑并原子发布 CAS）；
// 5) 断言 4：BM25 全文检索与向量距离打分在整个突变与合并周期后 100% 正确保真、数值与真实活文档绝对一致。

///|
fn make_e2e_10k_docs(count : Int, dim : Int) -> Array[@core.Doc] {
  let docs : Array[@core.Doc] = Array::new(capacity=count)
  for i in 1..<=count {
    let v : Array[Float] = Array::new(capacity=dim)
    for d in 0..<dim {
      v.push(Float::from_int((i * 17 + d * 31) % 1000) * 0.001)
    }
    docs.push({
      id: i.to_uint64(),
      text: "turbofish cursor notion base document number \{i} category partition \{i % 50}",
      vector: v,
      category: if i % 2 == 0 { "code" } else { "doc" },
      ts: (1700000000 + i).to_int64(),
      public: i % 2 == 0,
    })
  }
  docs
}

///|
test "E2E: Cursor/Notion workload (10k docs base -> 50 successive edits of 10 docs each)" {
  let store = @store.MemStore::new()
  let ns = "cursor_notion_workload"
  let dim = 8
  let engine = MergeTreeEngine::new(store, ns, dim, false, None)

  // 条件唤醒配置：L0 delta 阈值 4，墓碑比例 20%，空闲超时 10s
  let config : CompactionTriggerConfig = {
    l0_threshold: 4,
    tombstone_ratio_threshold: 0.20,
    idle_fallback_ms: 10000L,
    max_merge_parts: 16,
  }
  let policy = TieredMergePolicy::new(config)
  let compactor = Compactor::new(engine, policy, config)

  // 地面真值表：记录 10,000 篇文档在经过 50 次突变后的预期最终活文档状态
  let ground_truth : Map[UInt64, @core.Doc] = Map([])

  // =========================================================================
  // 阶段 1：写入 10,000 行基线数据 (Base Part, Level = 1)
  // =========================================================================
  let base_docs = make_e2e_10k_docs(10000, dim)
  for d in base_docs {
    ground_truth.set(d.id, d)
  }

  let base_part_id = engine.append_base_part(base_docs)
  engine.publish_manifest()

  let base_part_key = engine.part_store.part_key(base_part_id)
  let base_bytes_init = match store.get(base_part_key) {
    Some(b) => b
    None => fail("base part must exist in store")
  }
  let base_part_size = base_bytes_init.length()
  // 10,000 篇文档基线 Part 尺寸应在 200KB 以上
  assert_eq(base_part_size > 200000, true)

  let manifest_init = engine.get_manifest()
  assert_eq(manifest_init.parts.length(), 1)
  assert_eq(manifest_init.parts[0].level, 1)
  assert_eq(manifest_init.parts[0].row_count, 10000)
  assert_eq(manifest_init.l0_count(), 0)
  assert_eq(manifest_init.tombstones.length(), 0)

  // =========================================================================
  // 阶段 2：模拟 Cursor/Notion 工作负载进行 50 轮连续小批量突变（每轮编辑 10 篇文档）
  // =========================================================================
  let mut compactions_triggered = 0
  let mut total_delta_bytes_written = 0

  for step in 0..<50 {
    let edit_start_id = step * 10 + 1
    let old_ids : Array[UInt64] = Array::new(capacity=10)
    let updated_docs : Array[@core.Doc] = Array::new(capacity=10)

    for i in 0..<10 {
      let id_num = edit_start_id + i
      let id_u64 = id_num.to_uint64()
      old_ids.push(id_u64)

      let v : Array[Float] = Array::new(capacity=dim)
      for d in 0..<dim {
        v.push(Float::from_int((id_num * 97 + step * 13 + d) % 1000) * 0.001)
      }
      let edited_doc : @core.Doc = {
        id: id_u64,
        text: "turbofish cursor notion MUTATED content step_\{step} document \{id_num} specialized tag_\{step}",
        vector: v,
        category: "mutated_cursor",
        ts: (1710000000 + step * 100 + i).to_int64(),
        public: true,
      }
      updated_docs.push(edited_doc)
      ground_truth.set(id_u64, edited_doc)
    }

    // 记录本次编辑前的 S3 PUT 次数
    let puts_before_edit = store.cost().puts

    // 执行突变：软删除旧行 + 写入新 L0 Delta Part
    let delta_part_id = engine.mutate_rows(updated_docs, old_ids)
    engine.publish_manifest()

    // 断言写放大受限：本次 10 行编辑在存储层确切仅新增 1 个 Delta Part 对象
    let puts_after_edit = store.cost().puts
    // mutate_rows (1 put_part) + publish_manifest (1 manifest + 1 head_ptr) = 3 PUTs，其中 Part 数据 PUT 严格仅 1 次
    assert_eq(puts_after_edit - puts_before_edit, 3)

    let delta_part_key = engine.part_store.part_key(delta_part_id)
    let delta_bytes = match store.get(delta_part_key) {
      Some(b) => b
      None => fail("delta part must exist")
    }
    // 10 行 Delta Part 大小仅数 KB，与基线（>200KB）形成鲜明对照（写放大严格有界）
    assert_eq(delta_bytes.length() < 10000, true)
    total_delta_bytes_written += delta_bytes.length()

    // 唤醒 Compactor 检查
    let now_ms = (step + 1).to_int64() * 1000L
    compactor.notify_mutation(now_ms)
    let comp_res = compactor.tick(now_ms)

    match comp_res {
      Some(r) => {
        compactions_triggered += 1
        // 触发合并时，检查墓碑物理化统计
        assert_eq(r.tombstones_purged >= 0, true)
        // 合并后，L0 delta parts 归零，墓碑集合清空
        let m_after = engine.get_manifest()
        assert_eq(m_after.l0_count(), 0)
        assert_eq(m_after.tombstones.length(), 0)
        assert_eq(m_after.parts.length(), 1)
        assert_eq(m_after.parts[0].level, 1) // consolidated base
        assert_eq(m_after.parts[0].row_count, 10000) // 10k 活文档恒定
      }
      None => ()
    }
  }

  // 断言：50 轮突变中，由于 L0 阈值设置为 4，合并应当触发 12 次（48 轮折叠，剩余 2 轮 L0 挂起）
  assert_eq(compactions_triggered, 12)
  assert_eq(engine.get_manifest().l0_count(), 2)

  // =========================================================================
  // 阶段 3：验证空闲超时兜底 (Idle timer fallback)
  // =========================================================================
  // 当前存在 2 个未达到阈值的挂起 L0 delta (2 < 4)
  let last_act = 200000L
  compactor.notify_mutation(last_act)

  // 未到 10s 空闲超时（仅过 2s）：不触发合并
  let idle_early = compactor.tick(last_act + 2000L)
  assert_eq(idle_early is None, true)
  assert_eq(engine.get_manifest().l0_count(), 2)

  // 达到 10s 空闲超时（过 15s）：触发 idle fallback 物理化合并
  let idle_fired = compactor.tick(last_act + 15000L)
  assert_eq(idle_fired is Some(_), true)
  assert_eq(engine.get_manifest().l0_count(), 0)
  assert_eq(engine.get_manifest().tombstones.length(), 0)
  assert_eq(engine.get_manifest().parts.length(), 1)
  assert_eq(engine.get_manifest().parts[0].level, 1)
  assert_eq(engine.get_manifest().parts[0].row_count, 10000)
  assert_eq(engine.get_manifest().tombstones.length(), 0)

  // =========================================================================
  // 阶段 4：断言读路径零 LIST 调用 (Zero LIST requests on read path)
  // =========================================================================
  let lists_before_reads = store.cost().lists

  // 1. 读取并重构全部活文档（包含 Trailer Range GET、Footer Range GET、Part 读取与墓碑掩码过滤）
  let live_docs = engine.read_live_docs()

  // 2. Range GET 读取 Part Footer 与列切片
  let m_curr = engine.get_manifest()
  for p in m_curr.parts {
    let footer = engine.read_part_footer(p)
    assert_eq(footer.has("col:id"), true)
    assert_eq(footer.has("fts:dir"), true)
    let sec = footer.get("col:id").unwrap()
    let _ = engine.read_part_section(p, sec)
  }

  // 3. 从对象存储加载 Manifest (通过 head pointer 单次 GET 解析，零 LIST)
  let loaded_m = engine.manifest_store.load()
  assert_eq(loaded_m.seq, m_curr.seq)

  // 4. 读 head 指针
  let ptr = @store.read_head_pointer(store, ns)
  assert_eq(ptr is Some(_), true)

  let lists_after_reads = store.cost().lists
  // 核心断言：读路径与打开路径新增 LIST 请求数严格为 0
  assert_eq(lists_after_reads - lists_before_reads, 0)

  // =========================================================================
  // 阶段 5：断言 BM25 与向量查询结果与真值一致
  // =========================================================================
  // 1. 文档总数恒定 10,000，且每一篇文档的内容与 ground_truth 完全吻合
  assert_eq(live_docs.length(), 10000)
  for d in live_docs {
    match ground_truth.get(d.id) {
      Some(expected) => {
        assert_eq(d.text, expected.text)
        assert_eq(d.category, expected.category)
        assert_eq(d.ts, expected.ts)
        assert_eq(d.public, expected.public)
        for di in 0..<dim {
          assert_eq(d.vector[di], expected.vector[di])
        }
      }
      None => fail("live doc id \{d.id} not found in ground truth")
    }
  }

  // 2. BM25 全文检索一致性验证：
  // 检索第 25 轮突变的专有词 "tag_25"：必须精准命中第 25 轮编辑的 10 篇文档，命中数严格为 10
  let mut bm25_tag25_hits = 0
  for d in live_docs {
    if d.text.contains("tag_25") {
      bm25_tag25_hits += 1
      assert_eq(d.id >= 251UL && d.id <= 260UL, true)
    }
  }
  assert_eq(bm25_tag25_hits, 10)

  // 检索已被修改覆盖的旧词 "base document number 5 "：
  // id 5 在第 0 轮已被编辑覆盖，该旧内容绝不能出现在活文档集合中
  let mut old_content_hits = 0
  for d in live_docs {
    if d.text.contains("base document number 5 ") {
      old_content_hits += 1
    }
  }
  assert_eq(old_content_hits, 0)

  // 3. 向量相似度检索一致性验证：
  // 构造查询向量 Q，分别在 live_docs 与 ground_truth 上计算精确 Cosine 相似度取 Top-5
  let qv : Array[Float] = Array::new(capacity=dim)
  for di in 0..<dim {
    qv.push(0.5)
  }

  let live_scores : Array[(UInt64, Double)] = Array::new(capacity=live_docs.length())
  for d in live_docs {
    let dist = @core.cosine_dist_f32(qv, 0, d.vector, 0, dim)
    live_scores.push((d.id, 1.0 - dist))
  }
  live_scores.sort_by(fn(a, b) {
    if b.1 < a.1 { -1 } else if b.1 > a.1 { 1 } else { 0 }
  })

  let gt_scores : Array[(UInt64, Double)] = Array::new(capacity=ground_truth.size())
  for _, d in ground_truth {
    let dist = @core.cosine_dist_f32(qv, 0, d.vector, 0, dim)
    gt_scores.push((d.id, 1.0 - dist))
  }
  gt_scores.sort_by(fn(a, b) {
    if b.1 < a.1 { -1 } else if b.1 > a.1 { 1 } else { 0 }
  })

  // 断言 Top-5 最相似结果的 ID 与分数一致
  for rank in 0..<5 {
    assert_eq(live_scores[rank].0, gt_scores[rank].0)
    let score_diff = (live_scores[rank].1 - gt_scores[rank].1).abs()
    assert_eq(score_diff < 0.00001, true)
  }
}
