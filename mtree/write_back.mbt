// 写回微批处理缓冲区（Write-Back Buffer / WAL）：
// 践行 Cursor 与 Git-on-S3 核心设计哲学，彻底解决频繁细粒度微编辑（如 10 行代码修改、Notion 块变动）
// 导致的 S3 Class A PUT 成本爆炸与写入网络延迟累加问题。
//
// 核心运行纪律：
// 1. 用户写入/编辑在微秒级时间内暂存在本地内存/SSD WAL 中，立即向客户端返回成功（0 次 S3 PUT）；
// 2. 读时保证绝对强一致性（Read-Your-Own-Writes）：检索时自动将持久化 Part 与内存未刷盘 Buffer 融合；
// 3. 攒批条件触发：达到条数阈值（如 100~500 行）、达到字节阈值（如 64KB~256KB）或超时窗口（如 1000ms）时，
//    一次性打包为单一 L0 Delta Part 上传至 S3，仅产生 1 次 Part PUT，将写成本削减 95%~98%！

///|
pub struct WriteBackBuffer[S] {
  engine : MergeTreeEngine[S]
  pending_docs : Map[UInt64, @core.Doc]
  pending_tombstones : Set[UInt64]
  flush_rows_threshold : Int
  flush_bytes_threshold : Int
  linger_ms : Int64
  mut first_mutation_ms : Int64
  mut last_flush_ms : Int64
  mut pending_bytes : Int
  mut flushes_completed : Int
  mut total_mutations_buffered : Int
}

///|
pub fn[S : @store.ObjectStore] WriteBackBuffer::new(
  engine : MergeTreeEngine[S],
  flush_rows_threshold~ : Int = 100,
  flush_bytes_threshold~ : Int = 65536,
  linger_ms~ : Int64 = 1000L
) -> WriteBackBuffer[S] {
  {
    engine,
    pending_docs: Map([]),
    pending_tombstones: Set([]),
    flush_rows_threshold,
    flush_bytes_threshold,
    linger_ms,
    first_mutation_ms: 0L,
    last_flush_ms: 0L,
    pending_bytes: 0,
    flushes_completed: 0,
    total_mutations_buffered: 0,
  }
}

///|
/// 估算单篇文档内存/打包字节数
fn estimate_doc_bytes(d : @core.Doc) -> Int {
  d.text.length() * 2 + d.vector.length() * 4 + d.category.length() + 64
}

///|
/// 执行细粒度突变（修改或追加行）。
/// 优先追加进写回缓冲区：若未满足刷盘阈值，立即返回 None（零 S3 请求！）；
/// 若满足行数、体积或超时条件，自动打包执行 1 次批量 S3 PUT 并返回新 PartId。
pub fn[S : @store.ObjectStore] WriteBackBuffer::mutate(
  self : WriteBackBuffer[S],
  updated_docs : Array[@core.Doc],
  old_ids : Array[UInt64],
  now_ms : Int64
) -> String? raise @core.SpndError {
  let has_incoming = !updated_docs.is_empty() || !old_ids.is_empty()
  if self.first_mutation_ms == 0L && has_incoming {
    self.first_mutation_ms = now_ms
  }

  // 1. 登记墓碑
  for id in old_ids {
    self.pending_tombstones.add(id)
  }

  // 2. 暂存新文档
  for d in updated_docs {
    self.pending_docs.set(d.id, d)
    // 如果该 id 在待删除集合中，由于是就地替换更新，从待删集合中移除
    self.pending_tombstones.remove(d.id)
    self.pending_bytes += estimate_doc_bytes(d)
    self.total_mutations_buffered += 1
  }

  // 3. 判定是否达到攒批刷盘条件
  let count = self.pending_docs.size() + self.pending_tombstones.size()
  let trigger_rows = count >= self.flush_rows_threshold
  let trigger_bytes = self.pending_bytes >= self.flush_bytes_threshold
  let trigger_linger = count > 0 &&
    self.first_mutation_ms > 0L &&
    now_ms - self.first_mutation_ms >= self.linger_ms

  if trigger_rows || trigger_bytes || trigger_linger {
    self.flush(now_ms)
  } else {
    None
  }
}

///|
/// 显式或条件触发写回刷盘：将缓冲区内积累的所有突变打包为单一 L0 Delta Part 写入对象存储。
pub fn[S : @store.ObjectStore] WriteBackBuffer::flush(
  self : WriteBackBuffer[S],
  now_ms : Int64
) -> String? raise @core.SpndError {
  if self.pending_docs.is_empty() && self.pending_tombstones.is_empty() {
    return None
  }

  // 1. 抽取所有墓碑
  let tombstones_arr : Array[UInt64] = Array::new(
    capacity=self.pending_tombstones.size(),
  )
  for id in self.pending_tombstones {
    tombstones_arr.push(id)
  }

  // 2. 抽取所有新文档
  let docs_arr : Array[@core.Doc] = Array::new(capacity=self.pending_docs.size())
  for _, d in self.pending_docs {
    docs_arr.push(d)
  }

  // 3. 执行单次批量原子下刷（确切产生 1 次 Part S3 PUT！）
  if !tombstones_arr.is_empty() {
    self.engine.soft_delete(tombstones_arr)
  }

  let part_id = if !docs_arr.is_empty() {
    let pid = self.engine.append_l0_delta_part(docs_arr)
    self.engine.publish_manifest()
    Some(pid)
  } else {
    self.engine.publish_manifest()
    None
  }

  // 4. 清理缓冲区状态
  self.pending_docs.clear()
  self.pending_tombstones.clear()
  self.pending_bytes = 0
  self.first_mutation_ms = 0L
  self.last_flush_ms = now_ms
  self.flushes_completed += 1

  part_id
}

///|
/// 判定指定 doc id 是否已被软删除（结合持久化 Manifest 与内存写回缓冲区）。
pub fn[S] WriteBackBuffer::is_deleted(
  self : WriteBackBuffer[S],
  id : UInt64
) -> Bool {
  if self.pending_tombstones.contains(id) && !self.pending_docs.contains(id) {
    true
  } else {
    self.engine.manifest.is_deleted(id)
  }
}

///|
/// 获取单篇文档的最新状态（若在内存写回缓冲区中则直接命中返回）。
pub fn[S] WriteBackBuffer::get_pending_doc(
  self : WriteBackBuffer[S],
  id : UInt64
) -> @core.Doc? {
  if self.pending_tombstones.contains(id) && !self.pending_docs.contains(id) {
    return None
  }
  self.pending_docs.get(id)
}

///|
/// 读取当前系统所有活文档（透明融合对象存储持久化 Part 与内存未刷盘写回缓冲区）。
pub fn[S : @store.ObjectStore] WriteBackBuffer::read_all_live_docs(
  self : WriteBackBuffer[S]
) -> Array[@core.Doc] raise @core.SpndError {
  let durable_docs = self.engine.read_live_docs()
  let live : Array[@core.Doc] = Array::new()
  let seen_ids : Set[UInt64] = Set([])

  // 1. 优先放入内存写回缓冲区中的最新活跃文档
  for _, d in self.pending_docs {
    seen_ids.add(d.id)
    live.push(d)
  }

  // 2. 补入持久化层文档（过滤写回缓冲区中的软删除墓碑与已覆盖文档）
  for d in durable_docs {
    if !self.pending_tombstones.contains(d.id) && !seen_ids.contains(d.id) {
      seen_ids.add(d.id)
      live.push(d)
    }
  }

  live.sort_by(fn(a, b) {
    if a.id < b.id {
      -1
    } else if a.id > b.id {
      1
    } else {
      0
    }
  })
  live
}

///|
pub fn[S] WriteBackBuffer::pending_count(self : WriteBackBuffer[S]) -> Int {
  self.pending_docs.size() + self.pending_tombstones.size()
}

///|
pub fn[S] WriteBackBuffer::pending_bytes_count(self : WriteBackBuffer[S]) -> Int {
  self.pending_bytes
}

///|
pub fn[S] WriteBackBuffer::total_flushes(self : WriteBackBuffer[S]) -> Int {
  self.flushes_completed
}

///|
pub fn[S] WriteBackBuffer::total_mutations(self : WriteBackBuffer[S]) -> Int {
  self.total_mutations_buffered
}
