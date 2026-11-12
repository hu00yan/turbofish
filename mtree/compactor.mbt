// 后台 Compactor / Janitor 引擎（MergeTree 写路径合并器）。
//
// 核心职责：
// 1) 条件唤醒策略（Conditional Wake-up Policy）：
//    仅当 L0 delta part 数量 >= 阈值（默认 4）或 segment 中 tombstone 比例 >= 20% 时触发；
//    辅以 idle timer fallback 空闲回退；绝不常驻循环扫描 S3 LIST/HEAD。
// 2) 合并选中的 L0 parts + 现有 base parts 为新的 consolidated base part，
//    物理化清除 tombstone 软删除行，并通过 CAS 原子换代发布 manifest（发生并发冲突时自动 rebase 重试）。
// 3) 读写分离无锁：查询路径仅读取当前快照与不可变 part，合并过程全在后台运行，查询零阻塞。

///|
pub(all) struct CompactionResult {
  merged_parts_count : Int
  output_part_id : String
  output_row_count : Int
  tombstones_purged : Int
  new_seq : UInt64
} derive(Debug, Eq)

///|
pub struct Compactor[S] {
  engine : MergeTreeEngine[S]
  policy : TieredMergePolicy
  config : CompactionTriggerConfig
  mut last_active_ms : Int64
  mut wake_signaled : Bool
}

///|
pub fn[S : @store.ObjectStore] Compactor::new(
  engine : MergeTreeEngine[S],
  policy : TieredMergePolicy,
  config : CompactionTriggerConfig,
) -> Compactor[S] {
  {
    engine,
    policy,
    config,
    last_active_ms: 0L,
    wake_signaled: false,
  }
}

///|
/// 写者（追加 delta 或软删除）通知合并器。设置唤醒标记，绝不在 S3 上轮询 LIST。
pub fn[S] Compactor::notify_mutation(
  self : Compactor[S],
  now_ms : Int64,
) -> Unit {
  self.wake_signaled = true
  self.last_active_ms = now_ms
}

///|
/// 定时器驱动 tick。仅在收到写唤醒或达到空闲超时回退时才触发检查，
/// 严禁任何常驻轮询 S3 LIST/HEAD。
pub fn[S : @store.ObjectStore] Compactor::tick(
  self : Compactor[S],
  now_ms : Int64,
) -> CompactionResult? raise @core.SpndError {
  let idle_elapsed_ms = if self.last_active_ms > 0L && now_ms > self.last_active_ms {
    now_ms - self.last_active_ms
  } else {
    0L
  }

  // 若既无写唤醒通知，又未达到空闲回退时间，则直接休眠，零 S3 请求
  if !self.wake_signaled && idle_elapsed_ms < self.config.idle_fallback_ms {
    return None
  }

  self.compact_step(idle_elapsed_ms)
}

///|
/// 执行单步合并检查与物理化。
pub fn[S : @store.ObjectStore] Compactor::compact_step(
  self : Compactor[S],
  idle_elapsed_ms : Int64,
) -> CompactionResult? raise @core.SpndError {
  // 1. 获取当前最新 Manifest
  let manifest = self.engine.manifest

  // 2. 检查是否满足条件唤醒策略 (>=4 L0, 或 tombstone > 20%, 或 idle timer fallback)
  if !should_trigger_compaction(manifest, idle_elapsed_ms, self.config) {
    self.wake_signaled = false
    return None
  }

  // 3. 策略选取待合并 parts
  let picked_ids = match self.policy.pick(manifest.parts) {
    Some(ids) => ids
    None => {
      self.wake_signaled = false
      return None
    }
  }

  let picked_set : Set[String] = Set([])
  for pid in picked_ids {
    picked_set.add(pid)
  }

  // 4. 读取待合并 parts，物理化清除 tombstones，并以后写入的 L0 delta 覆盖旧行
  let roar_mask = manifest.tombstone_mask()
  let doc_map : Map[UInt64, @core.Doc] = Map([])

  // 按照 manifest 中的顺序读取并合并（先基线后 L0 delta，后写者覆盖先行）
  for pmeta in manifest.parts {
    if picked_set.contains(pmeta.part_id) {
      let footer = self.engine.read_part_footer(pmeta)
      let full_part = match
        PartStore::get_part(self.engine.part_store, pmeta.part_id) {
        Some(b) => b
        None =>
          raise @core.NotFound("compact part missing: \{pmeta.part_id}")
      }
      let docs = @format.decode_compact_part_docs(full_part, footer)
      for d in docs {
        if !@format.roaring_contains(roar_mask, d.id) {
          doc_map.set(d.id, d)
        }
      }
    }
  }

  let merged_docs : Array[@core.Doc] = Array::new(capacity=doc_map.size())
  for _, d in doc_map {
    merged_docs.push(d)
  }

  // 按 id 升序排序保真
  merged_docs.sort_by(fn(a, b) {
    if a.id < b.id {
      -1
    } else if a.id > b.id {
      1
    } else {
      0
    }
  })

  // 5. 编码写入新的 consolidated base part（仅 1 次 S3 PUT）
  let (new_part_bytes, _) = @format.encode_compact_part(
    merged_docs,
    self.engine.dim,
    self.engine.use_f16,
    self.engine.centroids,
  )
  let new_part_id = PartStore::put_part(self.engine.part_store, new_part_bytes)
  let min_id = if merged_docs.is_empty() { 0UL } else { merged_docs[0].id }
  let max_id = if merged_docs.is_empty() {
    0UL
  } else {
    merged_docs[merged_docs.length() - 1].id
  }

  let new_base_meta : PartMeta = {
    part_id: new_part_id,
    level: 1, // consolidated base
    row_count: merged_docs.length(),
    min_id,
    max_id,
    size_bytes: new_part_bytes.length(),
    tombstone_count: 0,
  }

  // 6. 原子换代发布新 manifest (CAS)，支持并发冲突 rebase 重试
  let mut current_manifest = manifest
  let mut retries = 0
  let mut purged_tombstones = 0

  while retries < 10 {
    // 构造新 parts 列表：保留未参与合并的 parts（如合并期间并发写入的新 L0 delta），加入新的 base part
    let remaining_parts : Array[PartMeta] = Array::new()
    if new_base_meta.row_count > 0 {
      remaining_parts.push(new_base_meta)
    }
    for p in current_manifest.parts {
      if !picked_set.contains(p.part_id) {
        remaining_parts.push(p)
      }
    }

    // 物理化清除已随合并抹除的 tombstones
    let remaining_tombstones : Array[UInt64] = Array::new()
    for t in current_manifest.tombstones {
      let mut is_purged = false
      for p in manifest.parts {
        if picked_set.contains(p.part_id) && t >= p.min_id && t <= p.max_id {
          is_purged = true
          break
        }
      }
      if is_purged {
        purged_tombstones += 1
      } else {
        remaining_tombstones.push(t)
      }
    }

    let next_manifest : Manifest = {
      seq: current_manifest.seq + 1UL,
      parts: remaining_parts,
      tombstones: remaining_tombstones,
    }

    try {
      ManifestStore::publish(self.engine.manifest_store, next_manifest)
      self.engine.manifest = next_manifest
      self.wake_signaled = false
      return Some({
        merged_parts_count: picked_ids.length(),
        output_part_id: new_part_id,
        output_row_count: merged_docs.length(),
        tombstones_purged: purged_tombstones,
        new_seq: next_manifest.seq,
      })
    } catch {
      @core.CommitConflict(_) => {
        // 并发写者导致 CAS 冲突：重新 load 最新的 manifest 进行 rebase 重试
        current_manifest = ManifestStore::load(self.engine.manifest_store)
        retries += 1
      }
      e => raise e
    }
  }

  raise @core.CommitConflict("compactor CAS retry exceeded max attempts")
}
